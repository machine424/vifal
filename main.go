package main

import (
	"context"
	"errors"
	"fmt"
	"hash/fnv"
	"log"
	"log/slog"
	"os"
	"os/exec"
	"os/signal"
	"path/filepath"
	"regexp"
	"runtime"
	"strconv"
	"strings"
	"sync"
	"syscall"
	"time"

	"github.com/hanwen/go-fuse/v2/fs"
	"github.com/hanwen/go-fuse/v2/fuse"
	"github.com/spf13/pflag"
	"golang.org/x/sys/unix"
	corev1 "k8s.io/api/core/v1"
	apierrors "k8s.io/apimachinery/pkg/api/errors"
	"k8s.io/cli-runtime/pkg/genericclioptions"
	"k8s.io/client-go/informers"
	"k8s.io/client-go/kubernetes"
	listerscorev1 "k8s.io/client-go/listers/core/v1"
	"k8s.io/client-go/rest"
	"k8s.io/client-go/tools/cache"
	"k8s.io/client-go/util/workqueue"

	"k8s.io/klog/v2"
	"k8s.io/kubectl/pkg/scheme"
)

const (
	defaultFSName = "vifal"
	subcmdUnmount = "unmount"
	containerRoot = "/"
)

var (
	// controls AttrTimeout, EntryTimeout, and cachedAttrs refresh
	attrTTL = 10 * time.Second

	informerResyncInterval = 30 * time.Second
	sessionBackoffDuration = 3 * time.Second

	logger         *log.Logger
	kubeFlags      *genericclioptions.ConfigFlags
	fuseMountpoint string

	// ASCII group separator, used as stat field delimiter.
	delimiter      = "\x1d"
	statFieldCount = 15
	statCmdSuffix  = "-maxdepth 1 -exec stat -c '%n\x1d%i\x1d%s\x1d%b\x1d%X\x1d%Y\x1d%Z\x1d%f\x1d%h\x1d%u\x1d%g\x1d%t\x1d%T\x1d%o\x1d%N' {} +"
)

func main() {
	if len(os.Args) > 1 && os.Args[1] == subcmdUnmount {
		cmdUnmount(os.Args[2:])
		return
	}
	cmdMount()
}

// initKubeFlags creates ConfigFlags exposing only --kubeconfig, --context, --cluster.
func initKubeFlags() {
	kubeFlags = genericclioptions.NewConfigFlags(true)
	kubeFlags.Namespace = nil
	kubeFlags.AuthInfoName = nil
	kubeFlags.Impersonate = nil
	kubeFlags.ImpersonateUID = nil
	kubeFlags.ImpersonateGroup = nil
	kubeFlags.Username = nil
	kubeFlags.Password = nil
	kubeFlags.APIServer = nil
	kubeFlags.TLSServerName = nil
	kubeFlags.Insecure = nil
	kubeFlags.CertFile = nil
	kubeFlags.KeyFile = nil
	kubeFlags.CAFile = nil
	kubeFlags.BearerToken = nil
	kubeFlags.Timeout = nil
	kubeFlags.CacheDir = nil
	kubeFlags.DisableCompression = nil
}

func cmdMount() {
	initKubeFlags()
	kubeFlags.AddFlags(pflag.CommandLine)

	debug := pflag.Bool("debug", false, "enable verbose logging")
	fsName := pflag.String("fsname", defaultFSName, "filesystem name")
	cacheTTL := pflag.Duration("attr-ttl", attrTTL, "TTL for attribute and directory caches")

	bin := filepath.Base(os.Args[0])
	pflag.Usage = func() {
		fmt.Fprintf(os.Stderr, `Usage: %[1]s [flags] MOUNTPOINT
       %[1]s %[2]s [--rm] [--force] MOUNTPOINT

Mount Kubernetes container filesystems locally via FUSE.

Example:
  %[1]s /tmp/vifal
  ls /tmp/vifal/                                         # namespaces
  ls /tmp/vifal/default/my-pod/my-container/etc/          # files
  cat /tmp/vifal/default/my-pod/my-container/etc/hosts    # read

Stop with Ctrl-C or kill, the mount is cleaned up automatically.
If the mount is stale (e.g. after SIGKILL or a crash):
  %[1]s %[2]s /tmp/vifal
  %[1]s %[2]s --force /tmp/vifal   # if "device busy"
  %[1]s %[2]s --rm /tmp/vifal      # also remove the directory

Note: "%[2]s" is a subcommand. To mount at a directory named "%[2]s",
use a path like "./%[2]s" instead.

Flags:
`, bin, subcmdUnmount)
		pflag.PrintDefaults()
	}
	pflag.Parse()

	if !*debug {
		// Suppress client-go/klog output.
		klog.SetSlogLogger(slog.New(slog.DiscardHandler))
	}

	logger = log.New(os.Stderr, *fsName+": ", log.LstdFlags|log.Lmsgprefix)

	if pflag.NArg() != 1 {
		pflag.Usage()
		os.Exit(1)
	}

	attrTTL = *cacheTTL
	negTTL := attrTTL / 2

	root, info, err := newRootNode()
	if err != nil {
		logger.Fatalf("failed to set up root node: %v", err)
	}

	fuseMountpoint = pflag.Arg(0)
	if isMountpoint(fuseMountpoint) {
		logger.Fatalf("%s is already a mountpoint", fuseMountpoint)
	}
	server, err := fs.Mount(fuseMountpoint, root, &fs.Options{
		MountOptions: fuse.MountOptions{
			Name:          *fsName,
			FsName:        fmt.Sprintf("%s://%s@%s", *fsName, info.Context, info.Server),
			Debug:         *debug,
			DisableXAttrs: true,
			MaxBackground: 64,
			// go-fuse derives both max_read and the macOS iosize mount
			// option from MaxWrite. Fewer round trips for large files.
			MaxWrite: 1 << 20,
			Options:  []string{"ro"},
			Logger:   log.New(os.Stderr, "fuse: ", log.LstdFlags),
		},
		AttrTimeout:     &attrTTL,
		EntryTimeout:    &attrTTL,
		NegativeTimeout: &negTTL,
		NullPermissions: true,
	})
	if err != nil {
		logger.Fatalf("failed to mount filesystem: %v", err)
	}
	ctx, stop := signal.NotifyContext(context.Background(), os.Interrupt, syscall.SIGTERM)
	defer stop()

	factory := informers.NewSharedInformerFactory(root.client, informerResyncInterval)
	root.queue = workqueue.NewTypedRateLimitingQueue(workqueue.DefaultTypedControllerRateLimiter[string]())

	namespaceInformer := factory.Core().V1().Namespaces()
	root.namespaceLister = namespaceInformer.Lister()
	podInformer := factory.Core().V1().Pods()
	root.podLister = podInformer.Lister()

	// Strips unnecessary fields from Pod objects to save memory.
	if err := podInformer.Informer().SetTransform(func(obj interface{}) (interface{}, error) {
		pod, ok := obj.(*corev1.Pod)
		if !ok {
			return obj, nil
		}
		stripped := make([]corev1.Container, len(pod.Spec.Containers))
		for i, c := range pod.Spec.Containers {
			stripped[i] = corev1.Container{Name: c.Name}
		}
		pod.Spec = corev1.PodSpec{Containers: stripped}
		pod.Status = corev1.PodStatus{}
		pod.ManagedFields = nil
		pod.Annotations = nil
		pod.Labels = nil
		pod.Finalizers = nil
		pod.OwnerReferences = nil
		return pod, nil
	}); err != nil {
		panic(fmt.Sprintf("setting pod transform: %v", err))
	}

	enqueue := func(obj interface{}) {
		key, err := cache.DeletionHandlingMetaNamespaceKeyFunc(obj)
		if err != nil {
			return
		}
		root.queue.Add(key)
	}
	handler := cache.ResourceEventHandlerFuncs{
		AddFunc:    enqueue,
		UpdateFunc: func(_, obj interface{}) { enqueue(obj) },
		DeleteFunc: enqueue,
	}
	if _, err := namespaceInformer.Informer().AddEventHandler(handler); err != nil {
		panic(fmt.Sprintf("adding namespace event handler: %v", err))
	}
	if _, err := podInformer.Informer().AddEventHandler(handler); err != nil {
		panic(fmt.Sprintf("adding pod event handler: %v", err))
	}

	factory.Start(ctx.Done())
	factory.WaitForCacheSync(ctx.Done())
	go root.runWorker(ctx)

	go func() {
		<-ctx.Done()
		root.queue.ShutDown()
		_ = server.Unmount()
	}()

	_ = server.WaitMount()
	logger.Printf("%s mounted at %s (kube_context=%s, kube_apiserver=%s)", *fsName, fuseMountpoint, info.Context, info.Server)

	server.Wait()
}

func cmdUnmount(args []string) {
	f := pflag.NewFlagSet(subcmdUnmount, pflag.ExitOnError)
	rm := f.Bool("rm", false, "remove the mountpoint directory even if unmount fails")
	force := f.Bool("force", false, "force unmount even if busy (lazy unmount)")

	bin := filepath.Base(os.Args[0])
	f.Usage = func() {
		fmt.Fprintf(os.Stderr, `Usage: %[1]s %[2]s [--rm] [--force] MOUNTPOINT

Unmount a FUSE mount. Normally not needed, Ctrl-C or kill cleanly
unmounts. Use this when the mount is stale (e.g. after SIGKILL or a crash).

Use --force if the regular unmount fails (e.g. "device busy").
Use --rm to remove the mountpoint directory (even if unmount fails).

Flags:
`, bin, subcmdUnmount)
		f.PrintDefaults()
	}
	_ = f.Parse(args)

	if f.NArg() != 1 {
		if info, err := os.Stat(subcmdUnmount); err == nil && info.IsDir() {
			fmt.Fprintf(os.Stderr, "hint: to mount at ./%[1]s, use: %s ./%[1]s\n\n", subcmdUnmount, bin)
		}
		f.Usage()
		os.Exit(1)
	}

	mountpoint := f.Arg(0)

	unmountErr := doUnmount(mountpoint, *force)
	if unmountErr != nil {
		fmt.Fprintf(os.Stderr, "unmount %s: %v\n", mountpoint, unmountErr)
	} else {
		fmt.Printf("unmounted %s\n", mountpoint)
	}

	if *rm {
		if err := os.RemoveAll(mountpoint); err != nil {
			fmt.Fprintf(os.Stderr, "remove %s: %v\n", mountpoint, err)
			os.Exit(1)
		}
		fmt.Printf("removed %s\n", mountpoint)
	} else if unmountErr != nil {
		os.Exit(1)
	}
}

// isMountpoint reports whether path is already a mountpoint by comparing
// device IDs with its parent (different device = mount boundary).
// TODO: This should probably be more cleanly handled by go-fuse.
func isMountpoint(path string) bool {
	var st, pst syscall.Stat_t
	if err := syscall.Stat(path, &st); err != nil {
		return false
	}
	if err := syscall.Stat(filepath.Dir(path), &pst); err != nil {
		return false
	}
	return st.Dev != pst.Dev
}

// doUnmount tries platform-appropriate unmount commands in order.
func doUnmount(mountpoint string, force bool) error {
	cmds := [][]string{{"fusermount", "-u", mountpoint}, {"umount", mountpoint}}
	if force {
		cmds = [][]string{{"fusermount", "-uz", mountpoint}, {"umount", "-l", mountpoint}}
	}
	if runtime.GOOS == "darwin" {
		cmds = [][]string{{"umount", mountpoint}, {"diskutil", "unmount", mountpoint}}
		if force {
			cmds = [][]string{{"umount", "-f", mountpoint}, {"diskutil", "unmount", "force", mountpoint}}
		}
	}

	var lastErr error
	for _, cmd := range cmds {
		out, err := exec.Command(cmd[0], cmd[1:]...).CombinedOutput()
		if err == nil {
			return nil
		}
		lastErr = fmt.Errorf("%s: %s", cmd[0], strings.TrimSpace(string(out)))
	}
	return lastErr
}

func newRootNode() (*rootNode, *kubeInfo, error) {
	config, info, err := getKubeConfig()
	if err != nil {
		return nil, nil, err
	}

	client, err := kubernetes.NewForConfig(config)
	if err != nil {
		return nil, nil, err
	}

	return &rootNode{
		client:    client,
		mountTime: uint64(time.Now().Unix()),
	}, info, nil
}

// rootNode is the mountpoint directory. Children are namespace directories.
type rootNode struct {
	fs.Inode

	client          kubernetes.Interface
	namespaceLister listerscorev1.NamespaceLister
	podLister       listerscorev1.PodLister
	queue           workqueue.TypedRateLimitingInterface[string]
	mountTime       uint64
}

var _ = (fs.InodeEmbedder)((*rootNode)(nil))
var _ = (fs.NodeAccesser)((*rootNode)(nil))
var _ = (fs.NodeGetattrer)((*rootNode)(nil))
var _ = (fs.NodeStatfser)((*rootNode)(nil))

// Access always returns OK. Without it go-fuse returns ENOSYS and
// tools like find and rsync bail out. Each node type needs its own
// method because go-fuse dispatches by concrete type.
func (r *rootNode) Access(ctx context.Context, mask uint32) syscall.Errno { return 0 }

func (r *rootNode) Getattr(ctx context.Context, f fs.FileHandle, out *fuse.AttrOut) syscall.Errno {
	out.Mode = r.Mode() | 0400
	out.Nlink = 2
	out.Blksize = 4096
	out.Atime = r.mountTime
	out.Mtime = r.mountTime
	out.Ctime = r.mountTime
	return 0
}

// Statfs returns cosmetic values.
// Block/inode counts are large sentinels meaning "unknown capacity".
// Bsize and NameLen must be non-zero or tools like df and glibc's
// realpath misbehave.
func (r *rootNode) Statfs(ctx context.Context, out *fuse.StatfsOut) syscall.Errno {
	out.Bsize = 4096
	out.Frsize = 4096
	out.NameLen = 255
	out.Blocks = 1 << 25
	out.Bfree = 1 << 25
	out.Bavail = 1 << 25
	out.Files = 1 << 20
	out.Ffree = 1 << 20
	return 0
}

func (r *rootNode) removeNamespace(name string) {
	nsNode := r.GetChild(name)
	if nsNode == nil {
		return
	}
	for _, podInode := range nsNode.Children() {
		closePodSessions(podInode)
	}
	r.RmChild(name)
	_ = r.NotifyDelete(name, nsNode)
}

func (r *rootNode) removePod(namespace, name string) {
	nsNode := r.GetChild(namespace)
	if nsNode == nil {
		return
	}
	if podInode := nsNode.GetChild(name); podInode != nil {
		closePodSessions(podInode)
		nsNode.RmChild(name)
		_ = nsNode.NotifyDelete(name, podInode)
	}
}

// runWorker drains the queue until shutdown.
func (r *rootNode) runWorker(ctx context.Context) {
	for r.processNextKey(ctx) {
	}
}

func (r *rootNode) processNextKey(ctx context.Context) bool {
	key, shutdown := r.queue.Get()
	if shutdown {
		return false
	}
	defer r.queue.Done(key)

	ns, name, splitErr := cache.SplitMetaNamespaceKey(key)
	if splitErr != nil {
		panic(fmt.Sprintf("invalid queue key %q: %v", key, splitErr))
	}
	var err error
	if ns == "" {
		err = r.reconcileNamespace(ctx, name)
	} else {
		err = r.reconcilePod(ctx, ns, name)
	}

	if err != nil {
		logger.Printf("processNextKey(%s): %v", key, err)
		r.queue.AddRateLimited(key)
		return true
	}
	r.queue.Forget(key)
	return true
}

// reconcileNamespace syncs the tree for one namespace against
// the informer cache. Creates or removes the directory as needed.
func (r *rootNode) reconcileNamespace(ctx context.Context, name string) error {
	ns, err := r.namespaceLister.Get(name)
	if apierrors.IsNotFound(err) {
		r.removeNamespace(name)
		return nil
	}
	if err != nil {
		return err
	}
	r.addNamespace(ctx, name, uint64(ns.CreationTimestamp.Unix()))
	return nil
}

// reconcilePod syncs a single pod. If the namespace does not exist in
// the lister cache the pod is silently skipped (the namespace delete
// will clean it up). If the namespace node is missing but the
// lister has the namespace, we create it here so event ordering does
// not matter.
func (r *rootNode) reconcilePod(ctx context.Context, namespace, name string) error {
	pod, err := r.podLister.Pods(namespace).Get(name)
	if apierrors.IsNotFound(err) {
		r.removePod(namespace, name)
		return nil
	}
	if err != nil {
		return err
	}

	if r.GetChild(namespace) == nil {
		ns, err := r.namespaceLister.Get(namespace)
		if apierrors.IsNotFound(err) {
			return nil
		}
		if err != nil {
			return err
		}
		r.addNamespace(ctx, namespace, uint64(ns.CreationTimestamp.Unix()))
	}

	r.addPod(ctx, pod)
	return nil
}

// addPod adds a pod inode. Skips if already present (same UID),
// replaces if a different pod reused the name. The caller must
// ensure the namespace node already exists.
func (r *rootNode) addPod(ctx context.Context, pod *corev1.Pod) {
	nsNode := r.GetChild(pod.Namespace)
	if nsNode == nil {
		return
	}

	if existing := nsNode.GetChild(pod.Name); existing != nil {
		if pn, ok := existing.Operations().(*podNode); ok && pn.uid == string(pod.UID) {
			return
		}
		closePodSessions(existing)
	}

	pNode := r.NewPersistentInode(ctx,
		&podNode{uid: string(pod.UID), creationTime: uint64(pod.CreationTimestamp.Unix())},
		fs.StableAttr{Mode: syscall.S_IFDIR})
	for _, container := range pod.Spec.Containers {
		cNode := r.NewPersistentInode(ctx,
			&containerNode{},
			fs.StableAttr{Mode: syscall.S_IFDIR})
		pNode.AddChild(container.Name, cNode, false)
	}
	nsNode.AddChild(pod.Name, pNode, true)
	_ = nsNode.NotifyEntry(pod.Name)
}

// addNamespace adds a namespace inode. No-op if already present.
func (r *rootNode) addNamespace(ctx context.Context, name string, creationTime uint64) *fs.Inode {
	node := r.NewPersistentInode(ctx, &namespaceNode{creationTime: creationTime}, fs.StableAttr{Mode: syscall.S_IFDIR})
	if r.AddChild(name, node, false) {
		return node
	}
	return r.GetChild(name)
}

// closePodSessions closes all exec sessions for every container in the pod.
func closePodSessions(podInode *fs.Inode) {
	for _, ci := range podInode.Children() {
		if cn, ok := ci.Operations().(*containerNode); ok {
			cn.sessionMu.Lock()
			if cn.execSession != nil {
				cn.execSession.close()
				cn.execSession = nil
			}
			cn.sessionMu.Unlock()
		}
	}
}

// namespaceNode represents a Kubernetes namespace.
type namespaceNode struct {
	fs.Inode
	creationTime uint64
}

var _ = (fs.InodeEmbedder)((*namespaceNode)(nil))
var _ = (fs.NodeAccesser)((*namespaceNode)(nil))
var _ = (fs.NodeGetattrer)((*namespaceNode)(nil))

// Access always returns OK (see rootNode.Access).
func (n *namespaceNode) Access(ctx context.Context, mask uint32) syscall.Errno { return 0 }

func (n *namespaceNode) Getattr(ctx context.Context, f fs.FileHandle, out *fuse.AttrOut) syscall.Errno {
	out.Mode = n.Mode() | 0400
	out.Nlink = 2
	out.Blksize = 4096
	out.Atime = n.creationTime
	out.Mtime = n.creationTime
	out.Ctime = n.creationTime
	return 0
}

// podNode represents a Kubernetes pod. uid detects replacements.
type podNode struct {
	fs.Inode
	uid          string
	creationTime uint64
}

var _ = (fs.InodeEmbedder)((*podNode)(nil))
var _ = (fs.NodeAccesser)((*podNode)(nil))
var _ = (fs.NodeGetattrer)((*podNode)(nil))

// Access always returns OK (see rootNode.Access).
func (n *podNode) Access(ctx context.Context, mask uint32) syscall.Errno { return 0 }

func (n *podNode) Getattr(ctx context.Context, f fs.FileHandle, out *fuse.AttrOut) syscall.Errno {
	out.Mode = n.Mode() | 0400
	out.Nlink = 2
	out.Blksize = 4096
	out.Atime = n.creationTime
	out.Mtime = n.creationTime
	out.Ctime = n.creationTime
	return 0
}

// containerNode represents a container inside a pod. Readdir and Lookup
// run find+stat inside the container via an execSession.
type containerNode struct {
	fs.Inode
	cachedAttrs

	sessionMu      sync.Mutex
	execSession    *execSession
	sessionBackoff time.Time
}

// extendedAttr wraps fuse.Attr with an optional symlink target from stat's %N.
type extendedAttr struct {
	fuse.Attr
	symlinkTarget []byte
}

// cachedAttrs caches find+stat results. Refreshed when the cache expires.
type cachedAttrs struct {
	attr          *extendedAttr
	childrenAttrs map[string]*extendedAttr
	lastUpdate    time.Time
	mu            sync.RWMutex
}

// updateNeeded reports whether the cache has expired.
func (ca *cachedAttrs) updateNeeded() bool {
	ca.mu.RLock()
	defer ca.mu.RUnlock()
	return time.Since(ca.lastUpdate) >= attrTTL
}

// storeAttrs saves fetched attrs, splitting selfPath's entry from children.
func (ca *cachedAttrs) storeAttrs(attrs map[string]*extendedAttr, selfPath string) error {
	entry := attrs[selfPath]
	if entry == nil {
		return errors.New("stat did not return entry for " + selfPath)
	}
	ca.mu.Lock()
	defer ca.mu.Unlock()
	ca.attr = entry
	delete(attrs, selfPath)
	ca.childrenAttrs = attrs
	ca.lastUpdate = time.Now()
	return nil
}

// getattr fills out from cached attr, returning EIO if unavailable.
func (ca *cachedAttrs) getattr(out *fuse.AttrOut) syscall.Errno {
	ca.mu.RLock()
	defer ca.mu.RUnlock()
	if ca.attr == nil {
		return syscall.EIO
	}
	out.Attr = ca.attr.Attr
	return 0
}

// readdir builds a DirEntry slice from cached children.
func (ca *cachedAttrs) readdir() []fuse.DirEntry {
	ca.mu.RLock()
	defer ca.mu.RUnlock()
	r := make([]fuse.DirEntry, 0, len(ca.childrenAttrs))
	for path, attr := range ca.childrenAttrs {
		r = append(r, fuse.DirEntry{
			Mode: attr.Mode,
			Name: filepath.Base(path),
			Ino:  attr.Ino,
		})
	}
	return r
}

// childAttr looks up a child by name.
func (ca *cachedAttrs) childAttr(name string) (string, *extendedAttr) {
	ca.mu.RLock()
	defer ca.mu.RUnlock()
	// TODO: if slow, add a name=>path index in storeAttrs.
	for path, attr := range ca.childrenAttrs {
		if filepath.Base(path) == name {
			return path, attr
		}
	}
	return "", nil
}

// lookupTime returns the initial cache time for a node. Files are fresh
// (attrs came from the parent listing). Directories start expired so
// the first access triggers their own find+stat.
func lookupTime(attr *extendedAttr) time.Time {
	if attr.Mode&syscall.S_IFDIR != 0 {
		return time.Time{}
	}
	return time.Now()
}

// nodeGen produces a unique Gen so go-fuse does not dedup nodes that happen
// to share the same inode number across different containers.
func nodeGen(containerIno uint64, absPath string) uint64 {
	h := fnv.New64a()
	h.Write([]byte(absPath))
	return h.Sum64() ^ containerIno
}

var _ = (fs.InodeEmbedder)((*containerNode)(nil))
var _ = (fs.NodeAccesser)((*containerNode)(nil))
var _ = (fs.NodeGetattrer)((*containerNode)(nil))
var _ = (fs.NodeReaddirer)((*containerNode)(nil))
var _ = (fs.NodeLookuper)((*containerNode)(nil))

// getExecSession returns the container's shell session, replacing it
// with a fresh one if the existing session is dead.
func (n *containerNode) getExecSession(ctx context.Context) (*execSession, error) {
	n.sessionMu.Lock()
	defer n.sessionMu.Unlock()

	if n.execSession != nil {
		if n.execSession.alive() {
			return n.execSession, nil
		}
		n.execSession.dead.Store(true)
		go n.execSession.close()
		n.execSession = nil
	}

	if time.Now().Before(n.sessionBackoff) {
		return nil, fmt.Errorf("session backoff active")
	}
	if err := n.startExecSession(ctx); err != nil {
		n.sessionBackoff = time.Now().Add(sessionBackoffDuration)
		return nil, err
	}
	return n.execSession, nil
}

// update refreshes cached attributes by running find+stat in the container.
// No-op if the cache is still fresh.
func (n *containerNode) update(ctx context.Context) error {
	if !n.updateNeeded() {
		return nil
	}

	session, err := n.getExecSession(ctx)
	if err != nil {
		return err
	}

	attrs, err := fetchDirAttrs(ctx, session, containerRoot)
	if err != nil {
		return err
	}

	return n.storeAttrs(attrs, containerRoot)
}

// startExecSession walks up the inode tree to collect container/pod/namespace
// names and creates a new execSession.
func (n *containerNode) startExecSession(ctx context.Context) error {
	containerName, pod := n.Parent()
	if pod == nil {
		return errors.New("pod node not found")
	}
	podName, namespace := pod.Parent()
	if namespace == nil {
		return errors.New("namespace node not found")
	}
	namespaceName, root := namespace.Parent()
	if root == nil {
		return errors.New("root node not found")
	}

	session, err := newExecSession(ctx, containerName, podName, namespaceName)
	if err != nil {
		return err
	}
	sessions.add(session)
	n.execSession = session
	go n.execSession.forwardOutput()
	return nil
}

// Access always returns OK (see rootNode.Access).
func (n *containerNode) Access(ctx context.Context, mask uint32) syscall.Errno { return 0 }

// Getattr returns attributes from the container's "/" via update() with a fallback to minimal default attrs.
func (n *containerNode) Getattr(ctx context.Context, f fs.FileHandle, out *fuse.AttrOut) syscall.Errno {
	if err := n.update(ctx); err != nil {
		logger.Printf("Getattr(%s): %v", n.Path(nil), err)
		// Container was discovered from the pod spec, so it should remain
		// visible in the tree even when unreachable.
		out.Mode = n.Mode() | 0400
		return 0
	}
	return n.getattr(out)
}

// Readdir lists the container's "/" children from cached attrs.
func (n *containerNode) Readdir(ctx context.Context) (fs.DirStream, syscall.Errno) {
	if err := n.update(ctx); err != nil {
		logger.Printf("Readdir(%s): %v", n.Path(nil), err)
		return nil, syscall.EIO
	}
	return fs.NewListDirStream(n.readdir()), 0
}

// Lookup resolves a child name inside the container root.
func (n *containerNode) Lookup(ctx context.Context, name string, out *fuse.EntryOut) (*fs.Inode, syscall.Errno) {
	if err := n.update(ctx); err != nil {
		logger.Printf("Lookup(%s/%s): %v", n.Path(nil), name, err)
		return nil, syscall.EIO
	}
	path, attr := n.childAttr(name)
	if attr == nil {
		return nil, syscall.ENOENT
	}
	out.Attr = attr.Attr
	return n.NewInode(ctx,
		&nodeInContainer{
			container:          n,
			absPathInContainer: path,
			cachedAttrs:        cachedAttrs{attr: attr, lastUpdate: lookupTime(attr)}},
		fs.StableAttr{Mode: attr.Mode, Ino: attr.Ino, Gen: nodeGen(n.StableAttr().Ino, path)}), 0
}

// nodeInContainer represents a file, directory, or symlink inside a container.
type nodeInContainer struct {
	fs.Inode
	cachedAttrs

	absPathInContainer string
	container          *containerNode
}

var _ = (fs.InodeEmbedder)((*nodeInContainer)(nil))
var _ = (fs.NodeAccesser)((*nodeInContainer)(nil))
var _ = (fs.NodeGetattrer)((*nodeInContainer)(nil))
var _ = (fs.NodeReaddirer)((*nodeInContainer)(nil))
var _ = (fs.NodeLookuper)((*nodeInContainer)(nil))
var _ = (fs.NodeOpener)((*nodeInContainer)(nil))
var _ = (fs.NodeReadlinker)((*nodeInContainer)(nil))

// Access always returns OK (see rootNode.Access).
func (n *nodeInContainer) Access(ctx context.Context, mask uint32) syscall.Errno { return 0 }

// Getattr returns cached attributes, refreshing via update() if stale.
func (n *nodeInContainer) Getattr(ctx context.Context, f fs.FileHandle, out *fuse.AttrOut) syscall.Errno {
	if err := n.update(ctx); err != nil {
		logger.Printf("Getattr(%s): %v", n.Path(nil), err)
		return syscall.EIO
	}
	return n.getattr(out)
}

// update refreshes cached attributes. Usually a no-op for files
// (fresh from parent Lookup). Directories start expired so the first
// access triggers a real fetch.
func (n *nodeInContainer) update(ctx context.Context) error {
	if !n.updateNeeded() {
		return nil
	}

	session, err := n.container.getExecSession(ctx)
	if err != nil {
		return err
	}

	attrs, err := fetchDirAttrs(ctx, session, n.absPathInContainer)
	if err != nil {
		return err
	}

	return n.storeAttrs(attrs, n.absPathInContainer)
}

// Readdir lists children from cached attrs.
func (n *nodeInContainer) Readdir(ctx context.Context) (fs.DirStream, syscall.Errno) {
	if err := n.update(ctx); err != nil {
		logger.Printf("Readdir(%s): %v", n.Path(nil), err)
		return nil, syscall.EIO
	}
	return fs.NewListDirStream(n.readdir()), 0
}

// Lookup resolves a child name inside a container directory.
func (n *nodeInContainer) Lookup(ctx context.Context, name string, out *fuse.EntryOut) (*fs.Inode, syscall.Errno) {
	if err := n.update(ctx); err != nil {
		logger.Printf("Lookup(%s/%s): %v", n.Path(nil), name, err)
		return nil, syscall.EIO
	}
	path, attr := n.childAttr(name)
	if attr == nil {
		return nil, syscall.ENOENT
	}
	out.Attr = attr.Attr
	return n.NewInode(ctx,
		&nodeInContainer{
			container:          n.container,
			absPathInContainer: path,
			cachedAttrs:        cachedAttrs{attr: attr, lastUpdate: lookupTime(attr)}},
		fs.StableAttr{Mode: attr.Mode, Ino: attr.Ino, Gen: nodeGen(n.container.StableAttr().Ino, path)}), 0
}

// Readlink returns the symlink target captured from stat's %N field.
// Absolute targets are rewritten to point through the mount so
// they resolve correctly (e.g. /var/log becomes
// /mnt/cluster/ns/pod/ctr/var/log).
func (n *nodeInContainer) Readlink(ctx context.Context) ([]byte, syscall.Errno) {
	if err := n.update(ctx); err != nil {
		logger.Printf("Readlink(%s): %v", n.Path(nil), err)
		return nil, syscall.EIO
	}
	target := string(n.attr.symlinkTarget)
	if filepath.IsAbs(target) {
		target = filepath.Join(fuseMountpoint, n.container.Path(nil), target)
	}
	return []byte(target), fs.OK
}

// Open returns a fileInContainer handle. Write flags are rejected with
// EROFS. FOPEN_DIRECT_IO bypasses the page cache so every read(2) calls
// Read, preventing stale cached content.
func (n *nodeInContainer) Open(ctx context.Context, flags uint32) (fh fs.FileHandle, fuseFlags uint32, errno syscall.Errno) {
	if flags&(syscall.O_WRONLY|syscall.O_RDWR|syscall.O_APPEND|syscall.O_CREAT|syscall.O_TRUNC) != 0 {
		return nil, 0, syscall.EROFS
	}
	return &fileInContainer{
		node: n,
	}, fuse.FOPEN_DIRECT_IO, 0
}

// fileInContainer is the file handle returned by Open.
type fileInContainer struct {
	node *nodeInContainer
}

var _ = (fs.FileReader)((*fileInContainer)(nil))

// Read runs dd inside the container to fetch the requested byte range.
// With FOPEN_DIRECT_IO the kernel never caches file data and always
// calls Read until we return 0 bytes (EOF). dd naturally returns
// empty output at EOF, so no size guard is needed.
func (n *fileInContainer) Read(ctx context.Context, dest []byte, offset int64) (fuse.ReadResult, syscall.Errno) {
	if err := n.node.update(ctx); err != nil {
		logger.Printf("Read(%s): %v", n.node.Path(nil), err)
		return nil, syscall.EIO
	}

	if len(dest) == 0 {
		return fuse.ReadResultData(nil), 0
	}

	bs, skip, count := ddParams(len(dest), int(offset))
	command := fmt.Appendf(nil, "dd if=%s bs=%d skip=%d count=%d status=none", shellQuote(n.node.absPathInContainer), bs, skip, count)

	session, err := n.node.container.getExecSession(ctx)
	if err != nil {
		logger.Printf("Read(%s): %v", n.node.Path(nil), err)
		return nil, syscall.EIO
	}

	output, err := session.exec(command)
	if err != nil {
		logger.Printf("Read(%s): %v", n.node.Path(nil), err)
		return nil, syscall.EIO
	}

	dest = dest[:0]
	for line := range output.commandStdout {
		dest = append(dest, line...)
	}

	res := <-output.commandErr
	if res.err != nil {
		logger.Printf("Read(%s): %v; stderr: %s", n.node.Path(nil), res.err, res.stderr)
		return nil, syscall.EIO
	}

	return fuse.ReadResultData(dest), 0
}

// parseStatRecord parses one stat record (fields separated by \x1d).
func parseStatRecord(record string) (string, *extendedAttr, error) {
	fields := strings.Split(record, delimiter)
	if len(fields) < statFieldCount {
		return "", nil, fmt.Errorf("got %d fields, want %d: %q", len(fields), statFieldCount, record)
	}

	path := fields[0]
	var symlinkTarget []byte
	if quoted := fields[statFieldCount-1]; strings.Contains(quoted, " -> ") {
		parts := strings.SplitN(quoted, " -> ", 2)
		symlinkTarget = []byte(strings.Trim(parts[1], "'\""))
	}

	var parseErr error
	parseField := func(s string, base, bits int) uint64 {
		if parseErr != nil {
			return 0
		}
		n, err := strconv.ParseUint(strings.TrimSpace(s), base, bits)
		if err != nil {
			parseErr = fmt.Errorf("field %q: %w", s, err)
		}
		return n
	}

	var attr fuse.Attr
	attr.Ino = parseField(fields[1], 10, 64)
	attr.Size = parseField(fields[2], 10, 64)
	attr.Blocks = parseField(fields[3], 10, 64)
	attr.Atime = parseField(fields[4], 10, 64)
	attr.Mtime = parseField(fields[5], 10, 64)
	attr.Ctime = parseField(fields[6], 10, 64)
	attr.Mode = uint32(parseField(fields[7], 16, 32))
	attr.Nlink = uint32(parseField(fields[8], 10, 64))
	attr.Uid = uint32(parseField(fields[9], 10, 64))
	attr.Gid = uint32(parseField(fields[10], 10, 64))
	major := uint32(parseField(fields[11], 16, 64))
	minor := uint32(parseField(fields[12], 16, 64))
	// Mkdev encodes for the host OS so stat on the mount shows correct major/minor.
	attr.Rdev = uint32(unix.Mkdev(major, minor))
	// On macOS, a non-zero Blksize overrides va_iosize per-vnode and caps
	// reads at fuse_round_iosize(blksize) (16 KiB for ext4's 4096).
	// Setting it to 0 lets macFUSE use the mount-level iosize (MaxWrite).
	// On Linux, Blksize only affects stat(2) output, so forward the real value.
	blksize := uint32(parseField(fields[13], 10, 64))
	if runtime.GOOS != "darwin" {
		attr.Blksize = blksize
	}
	if parseErr != nil {
		return "", nil, parseErr
	}

	return path, &extendedAttr{
		Attr:          attr,
		symlinkTarget: symlinkTarget,
	}, nil
}

// fetchDirAttrs runs find+stat for absPath and its immediate children.
// Returns a map keyed by absolute path, including absPath itself.
func fetchDirAttrs(ctx context.Context, session *execSession, absPath string) (map[string]*extendedAttr, error) {
	command := fmt.Appendf(nil, "find %s %s", shellQuote(absPath), statCmdSuffix)
	output, err := session.exec(command)
	if err != nil {
		return nil, err
	}

	// Unparseable records (e.g. filenames with newlines or \x1d) are skipped
	// rather than failing the whole listing.
	attrs := make(map[string]*extendedAttr)
	for raw := range output.commandStdout {
		line := strings.TrimRight(string(raw), "\n")
		if line == "" {
			continue
		}
		path, ea, err := parseStatRecord(line)
		if err != nil {
			logger.Printf("fetchDirAttrs(%s): skipping entry: %v", absPath, err)
			continue
		}
		attrs[path] = ea
	}
	if res := <-output.commandErr; res.err != nil {
		return nil, fmt.Errorf("fetchDirAttrs(%s): %w; stderr: %s", absPath, res.err, res.stderr)
	}
	return attrs, nil
}

// kubeInfo holds resolved Kubernetes connection details.
type kubeInfo struct {
	Context string
	Server  string
}

// getKubeConfig builds a Kubernetes client config from kubeFlags (cli-runtime).
// Sets API negotiation fields required by the raw REST client in exec_session.go.
func getKubeConfig() (*rest.Config, *kubeInfo, error) {
	c, err := kubeFlags.ToRESTConfig()
	if err != nil {
		return nil, nil, err
	}

	// The raw REST client needs explicit API negotiation settings.
	c.GroupVersion = &corev1.SchemeGroupVersion
	c.APIPath = "/api"
	c.NegotiatedSerializer = scheme.Codecs.WithoutConversion()

	info := &kubeInfo{Server: c.Host}
	if raw, err := kubeFlags.ToRawKubeConfigLoader().RawConfig(); err == nil {
		info.Context = raw.CurrentContext
	}

	return c, info, nil
}

var shellUnsafe = regexp.MustCompile(`[^\w@%+=:,./-]`)

// shellQuote wraps s in single quotes if it contains shell-unsafe characters.
func shellQuote(s string) string {
	if len(s) == 0 {
		return "''"
	}
	if !shellUnsafe.MatchString(s) {
		return s
	}
	return "'" + strings.ReplaceAll(s, "'", `'\''`) + "'"
}

// ddParams computes dd's bs, skip, and count to read bufferSize bytes
// starting at offset. Uses gcd(bufferSize, offset) as block size.
// Unaligned offsets (rare, only explicit pread) can yield small GCD
// (e.g. gcd(16384, 37)=1 => bs=1 count=16384).
// TODO: over-read from an aligned offset and trim in Go.
func ddParams(bufferSize, offset int) (bs int, skip int, count int) {
	gcd := func(a, b int) int {
		for b != 0 {
			a, b = b, a%b
		}
		return a
	}

	bs = gcd(bufferSize, offset)
	if bs == 0 {
		bs = 1
	}
	skip = offset / bs
	count = bufferSize / bs
	return
}
