"""Exclusive file lock for atomic read-modify-write on the habits profile JSON block.

Usage:
    with ProfileLock(path) as lock:
        text = lock.read()
        # ... modify text ...
        lock.write(new_text)   # atomic: tempfile + os.replace, never truncates on failure
"""
import fcntl, os, tempfile

class ProfileLock:
    def __init__(self, path):
        self._path = path
        self._lock_path = path + ".lock"
        self._lf = None

    def __enter__(self):
        self._lf = open(self._lock_path, 'w')
        fcntl.flock(self._lf.fileno(), fcntl.LOCK_EX)
        return self

    def read(self):
        with open(self._path) as fh:
            return fh.read()

    def write(self, text):
        # Atomic: write to a sibling tempfile, then rename over the target.
        # If the write fails (disk full, IO error) the original file is untouched.
        dir_ = os.path.dirname(self._path)
        fd, tmp = tempfile.mkstemp(dir=dir_, prefix=".profile-tmp-")
        try:
            with os.fdopen(fd, 'w') as fh:
                fh.write(text)
            os.replace(tmp, self._path)
        except Exception:
            try:
                os.unlink(tmp)
            except OSError:
                pass
            raise

    def __exit__(self, *_):
        if self._lf:
            self._lf.close()
