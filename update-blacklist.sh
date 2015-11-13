#!/bin/bash

IP_BLACKLIST_DIR=/etc/ipset-blacklist
IP_BLACKLIST_CONF="$IP_BLACKLIST_DIR/ipset-blacklist.conf"

if [ ! -f $IP_BLACKLIST_CONF ]; then
   echo "Error: please download the ipset-blacklist.conf configuration file from GitHub and move it to $IP_BLACKLIST_CONF (see docs)"
   exit 1
fi

source $IP_BLACKLIST_DIR/ipset-blacklist.conf

if ! which curl egrep grep ipset iptables sed sort wc &> /dev/null; then
    echo >&2 "Error: missing executables among: curl egrep grep ipset iptables sed sort wc"
    exit 1
fi

if [ ! -d $IP_BLACKLIST_DIR ]; then
    echo >&2 "Error: please create $IP_BLACKLIST_DIR directory"
    exit 1
fi

if [ -f /etc/ip-blacklist.conf ]; then
    echo >&2 "Error: please remove /etc/ip-blacklist.conf"
    exit 1
fi

if [ -f /etc/ip-blacklist-custom.conf ]; then
    echo >&2 "Error: Please reference your /etc/ip-blacklist-custom.conf as a file:// URI inside the BLACKLISTS array"
    exit 1
fi


# create the ipset if needed (or abort if does not exists and FORCE=no)
if ! ipset list -n|command grep -q "$IPSET_BLACKLIST_NAME"; then
    if [[ ${FORCE:-no} != yes ]]; then
	echo >&2 "Error: ipset does not exist yet, add it using:"
	echo >&2 "# ipset create $IPSET_BLACKLIST_NAME -exist hash:net family inet hashsize ${HASHSIZE:-65536}"
	exit 1
    fi
    if ! ipset create "$IPSET_BLACKLIST_NAME" -exist hash:net family inet hashsize "${HASHSIZE:-65536}"; then
	echo >&2 "Error: while creating the initial ipset"
	exit 1
    fi
fi

# create the iptables binding if needed (or abort if does not exists and FORCE=no)
if ! iptables -vL INPUT|command grep -q "match-set $IPSET_BLACKLIST_NAME"; then
    # we may also have assumed that INPUT rule n°1 is about packets statistics (traffic monitoring)
    if [[ ${FORCE:-no} != yes ]]; then
	echo >&2 "Error: iptables does not have the needed ipset INPUT rule, add it using:"
	echo >&2 "# iptables -I INPUT 1 -m set --match-set $IPSET_BLACKLIST_NAME src -j DROP"
	exit 1
    fi
    if ! iptables -I INPUT 2 -m set --match-set $IPSET_BLACKLIST_NAME src -j DROP; then
	echo >&2 "Error: while adding the --match-set ipset rule to iptables"
	exit 1
    fi
fi

IP_BLACKLIST_TMP=$(mktemp)
for i in "${BLACKLISTS[@]}"
do
    IP_TMP=$(mktemp)
    let HTTP_RC=`curl  -A "blacklist-update/script/github" --connect-timeout 10 --max-time 10 -o $IP_TMP -s -w "%{http_code}" "$i"`
    if (( $HTTP_RC == 200 || $HTTP_RC == 302 || $HTTP_RC == 0 )); then # "0" because file:/// returns 000
        command grep -Po '(?:\d{1,3}\.){3}\d{1,3}(?:/\d{1,2})?' $IP_TMP >> $IP_BLACKLIST_TMP
	[[ $VERBOSE == yes ]] && echo -n "."
    else
        echo >&2 -e "\nWarning: curl returned HTTP response code $HTTP_RC for URL $i"
    fi
    rm -f "$IP_TMP"
done

# sort -nu does not work as expected
sed -r -e '/^(10\.|127\.|172\.16\.|192\.168\.)/d' "$IP_BLACKLIST_TMP"|sort -n|sort -mu >| "$IP_BLACKLIST"
rm -f "$IP_BLACKLIST_TMP"

# family = inet for IPv4 only
cat >| "$IP_BLACKLIST_RESTORE" <<EOF
create $IPSET_TMP_BLACKLIST_NAME -exist hash:net family inet hashsize ${HASHSIZE:-65536} maxelem ${MAXELEM:-65536}
create $IPSET_BLACKLIST_NAME -exist hash:net family inet hashsize ${HASHSIZE:-65536} maxelem ${MAXELEM:-65536}
EOF


# can be IPv4 including netmask notation
# IPv6 ? -e "s/^([0-9a-f:./]+).*/add $IPSET_TMP_BLACKLIST_NAME \1/p" \ IPv6
sed -rn -e '/^#|^$/d' \
    -e "s/^([0-9./]+).*/add $IPSET_TMP_BLACKLIST_NAME \1/p" "$IP_BLACKLIST" >> "$IP_BLACKLIST_RESTORE"

cat >> "$IP_BLACKLIST_RESTORE" <<EOF
swap $IPSET_BLACKLIST_NAME $IPSET_TMP_BLACKLIST_NAME
destroy $IPSET_TMP_BLACKLIST_NAME
EOF

ipset -file  "$IP_BLACKLIST_RESTORE" restore

if [[ ${VERBOSE:-no} == yes ]]; then
    echo
    echo "Number of blacklisted IP/networks found: `wc -l $IP_BLACKLIST | cut -d' ' -f1`"
fi
