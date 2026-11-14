#!/bin/sh
# Shows a PNG with the kitty graphics protocol, fitted to the pane and centered, with a caption
# on the last line. Any key closes it. Redraws when the pane is resized.
#
#   view.sh IMAGE.png [CAPTION [CELL_WIDTH CELL_HEIGHT]]
#
# IMAGE is the quicklook plugin's own copy: it is deleted on exit, with its directory if that is
# then empty. The cell size, in pixels, is given rather than asked of the terminal: an answer
# would arrive mixed with the keys that close the viewer. It is 8 by 16 when not given.

# Whether $1 is a whole number above 0.
positive() {
	case $1 in '' | *[!0-9]* | 0*) return 1 ;; esac
}

img=$1
cw=8 ch=16
if positive "$3" && positive "$4"; then
	cw=$3 ch=$4
fi
# The caption is a file's name, not terminal markup: control characters (C0, DEL and C1) show
# as `?`.
caption=$(printf %s "${2:-$(basename "$img")}" | LC_ALL=C tr '\000-\037\177' '?' |
	LC_ALL=C sed "s/$(printf '\302[\200-\237]')/?/g")

saved=$(stty -g)
cleanup() {
	printf '\033_Ga=d,d=A,q=2\033\\\033[?25h\033[?1049l'
	stty "$saved"
	rm -f "$img"
	rmdir "$(dirname "$img")" 2>/dev/null
}
trap cleanup EXIT
trap 'exit 0' HUP INT TERM

# Raw input: a read returns after one byte, or after 0.3 s with none.
stty raw -echo min 0 time 3
printf '\033[?1049h\033[?25l'

# The image's size in pixels, from its PNG header.
set -- $(od -An -tu1 -j16 -N8 "$img")
[ $# -eq 8 ] || exit 1
iw=$(( ($1 << 24) | ($2 << 16) | ($3 << 8) | $4 ))
ih=$(( ($5 << 24) | ($6 << 16) | ($7 << 8) | $8 ))
[ "$iw" -gt 0 ] && [ "$ih" -gt 0 ] || exit 1
name=$(printf %s "$img" | base64 | tr -d '\n')

# One byte of input, or nothing after the read timeout.
byte() {
	dd bs=1 count=1 2>/dev/null
}

draw() {
	set -- $(stty size)
	rows=$1 cols=$2
	[ "$cols" -ge 1 ] || cols=1
	# The last line is the caption's.
	area=$((rows - 1))
	[ "$area" -ge 1 ] || area=1
	aw=$((cols * cw)) ah=$((area * ch))
	# Fit, keeping the aspect ratio; give only the side that limits it, so the terminal works
	# out the other from the image.
	if [ $((iw * ah)) -ge $((ih * aw)) ]; then
		c=$cols
		r=$(((ih * aw / iw + ch - 1) / ch))
		fit="c=$c"
	else
		r=$area
		c=$(((iw * ah / ih + cw - 1) / cw))
		fit="r=$r"
	fi
	[ "$r" -le "$area" ] || r=$area
	[ "$c" -le "$cols" ] || c=$cols
	x=$(((cols - c) / 2 + 1)) y=$(((area - r) / 2 + 1))
	printf '\033_Ga=d,d=A,q=2\033\\\033[2J'
	printf '\033[%d;%dH\033_Ga=T,t=f,f=100,C=1,q=2,%s;%s\033\\' "$y" "$x" "$fit" "$name"
	text=$(printf '%s  (any key closes)' "$caption" | cut -c1-"$cols")
	printf '\033[%d;%dH\033[2m%s\033[0m' "$rows" $(((cols - ${#text}) / 2 + 1)) "$text"
}

resized=1
trap 'resized=1' WINCH
while :; do
	if [ "$resized" = 1 ]; then
		resized=0
		draw
	fi
	[ -n "$(byte | od -An -c)" ] && break
done
