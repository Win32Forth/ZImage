package move

import "golang.org/x/sys/unix"

const spareBytes = 1 << 30

func (r *Runner) freeBytes() (uint64, error) {
	if r.Free != nil {
		return r.Free(r.Root)
	}
	var stat unix.Statfs_t
	if err := unix.Statfs(r.Root, &stat); err != nil {
		return 0, err
	}
	return uint64(stat.Bavail) * uint64(stat.Bsize), nil
}
