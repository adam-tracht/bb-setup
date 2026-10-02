#!/bin/sh
# bb custom ACP agent shim for prime-agent (managed by bb-plugin-prime-agent-provider).
#   pa-acp.sh model-list            -> reformat `prime-agent model list` for bb's parser
#   pa-acp.sh <bb launch args...>   -> exec prime-agent, translating
#                                      `--model <provider>/<model>` into
#                                      `--model <model> --provider <provider>`
export PATH="__HOME__/.nvm/versions/node/v22.23.2/bin:$PATH"
PRIME_AGENT_BIN="__HOME__/.nvm/versions/node/v22.23.2/bin/prime-agent"
if [ "$1" = "model-list" ]; then
	shift
	# prime-agent prints the table to stderr (stdout is reserved); merge it.
	"$PRIME_AGENT_BIN" model list "$@" 2>&1 | awk 'NR > 1 && NF == 6 { print $1 "/" $2 " - " $2 " (" $1 ")" }'
	exit 0
fi

out=""
prev_model=0
for a in "$@"; do
	if [ "$prev_model" = 1 ]; then
		case "$a" in
			*/*) p="${a%%/*}"; m="${a#*/}"; out="$out --model $m --provider $p" ;;
			*) out="$out --model $a" ;;
		esac
		prev_model=0
	elif [ "$a" = "--model" ]; then
		prev_model=1
	else
		out="$out $a"
	fi
done
# shellcheck disable=SC2086
exec "$PRIME_AGENT_BIN" $out
