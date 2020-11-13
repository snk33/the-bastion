#! /usr/bin/env bash
# vim: set filetype=sh ts=4 sw=4 sts=4 et:
set -e
umask 077

basedir=$(readlink -f "$(dirname "$0")"/../..)
# shellcheck source=lib/shell/functions.inc
. "$basedir"/lib/shell/functions.inc

if command -v gpg1 >/dev/null 2>&1; then
    gpgcmd="gpg1"
else
    gpgcmd="gpg"
fi

do_generate()
{
    key_size=4096
    rsync_conf="$BASTION_ETC_DIR/osh-encrypt-rsync.conf.d/50-gpg-bastion-key.conf"
    if [ -e "$rsync_conf" ]; then
        echo "$rsync_conf already exists, aborting!" >&2
        exit 1
    fi
    test -d "$BASTION_ETC_DIR/osh-encrypt-rsync.conf.d" || mkdir "$BASTION_ETC_DIR/osh-encrypt-rsync.conf.d"

    sign_key_pass=$(perl -e '$p .= chr(int(rand(93))+33) for (1..16); $p =~ s{["\\]}{~}g; print "$p"')
    printf "Key-Type: RSA\\nKey-Length: $key_size\\nSubkey-Type: RSA\\nSubkey-Length: $key_size\\nName-Real: %s\\nName-Comment: Bastion signing key\\nName-Email: %s\\nExpire-Date: 0\\nPassphrase: %s\\n%%echo Generating GPG key, it'll take some time.\\n%%commit\\n%%echo done\\n" "$(hostname)" "root@$(hostname)" "$sign_key_pass" | $gpgcmd --gen-key --batch

    # get the id of the key we just generated
    gpgid=$($gpgcmd --with-colons --list-keys "$(hostname) (Bastion signing key) <root@$(hostname)>" | awk -F: '/^pub:/ { print $5; exit; }')

    if [ -z "$gpgid" ]; then
        echo "Error while generating key, couldn't find the ID in gpg --list-keys :(" >&2
        return 1
    fi

    cat > "$rsync_conf" <<EOF
# autogenerated with $0 at $(date)
{
    "signing_key_passphrase": "$sign_key_pass",
    "signing_key": "$gpgid"
}
EOF
    chown "$UID0":"$GID0" "$rsync_conf"
    chmod 600 "$rsync_conf"

    echo
    echo "Configuration file $rsync_conf updated:"
    echo "8<---8<---8<---8<---8<---8<--"
    cat "$rsync_conf"
    echo "--->8--->8--->8--->8--->8--->8"

    echo
    echo Done.
}

do_import()
{
    rsync_conf="$BASTION_ETC_DIR/osh-encrypt-rsync.conf.d/50-gpg-admins-key.conf"
    if [ -e "$rsync_conf" ]; then
        echo "$rsync_conf already exists, aborting!" >&2
        exit 1
    fi
    test -d "$BASTION_ETC_DIR/osh-encrypt-rsync.conf.d" || mkdir "$BASTION_ETC_DIR/osh-encrypt-rsync.conf.d"
    backup_conf="$BASTION_ETC_DIR/osh-backup-acl-keys.conf.d/50-gpg.conf"
    if [ -e "$backup_conf" ]; then
        echo "$backup_conf already exists, aborting!" >&2
        exit 1
    fi
    test -d "$BASTION_ETC_DIR/osh-backup-acl-keys.conf.d" || mkdir "$BASTION_ETC_DIR/osh-backup-acl-keys.conf.d"

    keys_before=$(mktemp)
    # shellcheck disable=SC2064
    trap "rm -f $keys_before" EXIT INT
    $gpgcmd --with-colons --list-keys | grep ^pub: | awk -F: '{print $5}' > "$keys_before"
    echo "Paste the admins public GPG key:"
    $gpgcmd --import
    newkey=''
    for key in $($gpgcmd --with-colons --list-keys | grep ^pub: | awk -F: '{print $5}'); do
        grep -qw "$key" "$keys_before" || newkey="$key"
    done
    if [ -z "$newkey" ]; then
        echo "Couldn't find which key you imported, aborting" >&2
        return 1
    fi
    echo "Found generated key with ID: $newkey"
    fpr=$($gpgcmd --with-colons --fingerprint --list-keys "$newkey" | awk -F: '/^fpr:/ {print $10 ; exit}')
    if [ -z "$fpr" ]; then
        echo "Couldn't find the fingerprint of the generated key $newkey, aborting" >&2
        return 1
    fi
    echo "Found generated key fingerprint: $fpr"
    echo "Trusting this key..."
    $gpgcmd --import-ownertrust <<< "$fpr:6:"

    cat > "$rsync_conf" <<EOF
# autogenerated with $0 at $(date)
{
    "recipients": [
        [ "$newkey" ]
    ]
}
EOF
    chown "$UID0":"$GID0" "$rsync_conf"
    chmod 600 "$rsync_conf"

    echo
    echo "Configuration file $rsync_conf updated:"
    echo "8<---8<---8<---8<---8<---8<--"
    cat "$rsync_conf"
    echo "--->8--->8--->8--->8--->8--->8"

    cat > "$backup_conf" <<EOF
# autogenerated with $0 at $(date)
GPGKEYS='$newkey'
EOF
    chown "$UID0":"$GID0" "$backup_conf"
    chmod 600 "$backup_conf"

    echo
    echo "Configuration file $backup_conf updated:"
    echo "8<---8<---8<---8<---8<---8<--"
    cat "$backup_conf"
    echo "--->8--->8--->8--->8--->8--->8"

    echo
    echo Done.

}

if [ "$1" = "--import" ]; then
    do_import; exit $?
elif [ "$1" = "--generate" ]; then
    do_generate; exit $?
fi

echo "Usage: $0 <--import|--generate>"
echo
echo "Use --generate to generate a new GPG key pair for bastion signing"
echo "Use --import to import the administrator GPG key you've generated on your desk (ttyrecs, keys and acls backups will be encrypted to it)"
exit 0