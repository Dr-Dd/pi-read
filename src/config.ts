/**
 * Where pi-share is installed. This is the same path as PI_SHARE_DEST in install.sh, which puts
 * the script there and writes the matching sudoers rule; tests/share-path.test.ts fails when the
 * two differ.
 */
export const PI_SHARE_PATH = "/usr/local/bin/pi-share";

/**
 * Where pi-share reads the never-share list (root-owned, edited in place by root). The same path as
 * NEVER_SHARE_DEST in install.sh and NEVER_SHARE_LIST in bin/pi-share;
 * tests/never-share-path.test.ts fails when they differ.
 */
export const NEVER_SHARE_LIST_PATH = "/usr/local/etc/pi-read/never-share.list";
