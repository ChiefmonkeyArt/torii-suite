// Read a small file the unprivileged Continuum agent controls, as root,
// without following links anywhere else (shared by the FIPS and Teams helpers).
import { closeSync, constants, fstatSync, openSync, readFileSync, realpathSync } from 'node:fs';
import { dirname } from 'node:path';

export function readAgentFile(path, maxBytes) {
  if (realpathSync(dirname(path)) !== dirname(path)) throw new Error('request directory is a link');
  const fd = openSync(path, constants.O_RDONLY | constants.O_NOFOLLOW);
  try {
    const st = fstatSync(fd);
    if (!st.isFile() || st.size > maxBytes) throw new Error('request must be a small regular file');
    return readFileSync(fd, 'utf8');
  } finally { closeSync(fd); }
}
