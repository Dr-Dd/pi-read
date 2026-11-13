/**
 * Where pi-share is installed. This is the same path as PI_SHARE_DEST in install.sh, which puts
 * the script there and writes the matching sudoers rule; tests/share-path.test.ts fails when the
 * two differ.
 */
export const PI_SHARE_PATH = "/usr/local/bin/pi-share";
