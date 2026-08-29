# Writes a pretty, build-stamped welcome banner, plus an Ubuntu-style
# colored interactive shell (prompt + ls/grep colors), to the rootfs.
#
# Two separate mechanisms, deliberately not one file:
#
# - /etc/issue: shown by agetty on the LOCAL/SERIAL console before login.
#   agetty substitutes its own escapes here (\n = hostname, \l = tty) and
#   passes raw ANSI color codes straight through to the terminal.
# - /etc/profile.d/imx93-banner.sh: shown on every interactive login shell
#   (console after `login`, AND SSH) via real shell code run at login time.
#
# These must NOT be the same file. A previous version of this class wrote
# identical content -- \n/\l escapes included -- to /etc/motd too. sshd's
# PrintMotd and PAM's pam_motd both just `cat` /etc/motd verbatim with zero
# escape processing (neither is agetty), so over SSH the literal text
# "\n \l" showed up in the terminal instead of a hostname/tty. Computing
# hostname/tty/login-time live in a profile.d script sidesteps the problem
# entirely instead of trying to patch around it, and as a bonus is always
# correct (a static file can only ever bake in build-time values).
#
# Usage: inherit this class from an image recipe. IMX93_BUILDER can be
# overridden per build (e.g. in local.conf) if someone other than the
# default builder produces a given image.

# Derived from bitbake.conf's DATE/TIME (both "${@time.strftime(...)}",
# UTC), NOT a fresh time.strftime() call of our own. DATE/TIME live in
# bitbake.conf, parsed once per bitbake server lifetime, so they're fixed
# for the whole invocation. This class gets re-included on every parse of
# any recipe that inherits it -- a fresh time.strftime() here would return
# a different value on each of those reparses (seconds ticking over is
# enough), and BitBake explicitly checks for exactly that kind of
# metadata non-determinism before running a task, failing the build with
# "the basehash value changed" if caught. Slicing the already-fixed
# DATE/TIME strings keeps this deterministic across reparses.
IMX93_BUILD_TIMESTAMP := "${@'%s-%s-%s %s:%s:%s UTC' % ('${DATE}'[0:4], '${DATE}'[4:6], '${DATE}'[6:8], '${TIME}'[0:2], '${TIME}'[2:4], '${TIME}'[4:6])}"
IMX93_BUILDER ?= "Khaled El-Sayed"

ROOTFS_POSTPROCESS_COMMAND += "imx93_write_welcome_banner "

imx93_write_welcome_banner () {
	install -d "${IMAGE_ROOTFS}${sysconfdir}/profile.d"

	# --- /etc/issue: pre-login banner, local/serial console only -----------
	# Built with `printf`, not a heredoc: printf's own \033 octal-escape
	# handling gives real ANSI bytes, while \\n / \\l below still land in
	# the file as the literal two-character text "\n"/"\l" for agetty to
	# substitute -- a heredoc can't easily do both at once.
	issue="${IMAGE_ROOTFS}${sysconfdir}/issue"
	: > "$issue"
	printf '\033[1;36m********************************************************\033[0m\n' >> "$issue"
	printf '\033[1;36m*\033[0m  \033[1;33m[IMX93-CUSTOM]\033[0m NXP i.MX93 FRDM Security Testing Image\n' >> "$issue"
	printf '\033[1;36m********************************************************\033[0m\n' >> "$issue"
	printf "\033[1;36m*\033[0m  Image      : \033[1;32m${PN}\033[0m\n" >> "$issue"
	printf "\033[1;36m*\033[0m  Machine    : \033[1;32m${MACHINE}\033[0m\n" >> "$issue"
	printf "\033[1;36m*\033[0m  Distro     : \033[1;32m${DISTRO} ${DISTRO_VERSION}\033[0m\n" >> "$issue"
	printf "\033[1;36m*\033[0m  Built      : \033[1;32m${IMX93_BUILD_TIMESTAMP}\033[0m\n" >> "$issue"
	printf "\033[1;36m*\033[0m  Builder    : \033[1;32m${IMX93_BUILDER}\033[0m\n" >> "$issue"
	printf '\033[1;36m********************************************************\033[0m\n' >> "$issue"
	printf '\n' >> "$issue"
	printf '\\n \\l\n' >> "$issue"
	printf '\n' >> "$issue"

	# --- static build facts, read at every login by the profile.d banner ---
	buildinfo="${IMAGE_ROOTFS}${sysconfdir}/imx93-build-info"
	cat > "$buildinfo" <<EOF
IMX93_BI_IMAGE="${PN}"
IMX93_BI_MACHINE="${MACHINE}"
IMX93_BI_DISTRO="${DISTRO} ${DISTRO_VERSION}"
IMX93_BI_BUILT="${IMX93_BUILD_TIMESTAMP}"
IMX93_BI_BUILDER="${IMX93_BUILDER}"
EOF

	# --- dynamic, colorful post-login banner: console AND SSH alike --------
	# Quoted heredoc ('EOF') -- this content must NOT be substituted by
	# bitbake at build time; it's a real shell script, evaluated live on
	# the board at every login.
	cat > "${IMAGE_ROOTFS}${sysconfdir}/profile.d/imx93-banner.sh" <<'EOF'
# IMX93-CUSTOM colorful login banner. Interactive top-level shells only.
case "$-" in *i*) : ;; *) return 2>/dev/null || exit 0 ;; esac
[ "${SHLVL:-1}" -eq 1 ] || return 2>/dev/null || exit 0

[ -r /etc/imx93-build-info ] && . /etc/imx93-build-info

_c_b='\033[1;36m'; _c_y='\033[1;33m'; _c_g='\033[1;32m'; _c_r='\033[0m'
_ip="$(hostname -I 2>/dev/null | awk '{print $1}')"

printf "${_c_b}********************************************************${_c_r}\n"
printf "${_c_b}*${_c_r}  ${_c_y}[IMX93-CUSTOM]${_c_r} NXP i.MX93 FRDM Security Testing Image\n"
printf "${_c_b}********************************************************${_c_r}\n"
printf "${_c_b}*${_c_r}  Image      : ${_c_g}%s${_c_r}\n" "${IMX93_BI_IMAGE:-unknown}"
printf "${_c_b}*${_c_r}  Machine    : ${_c_g}%s${_c_r}\n" "${IMX93_BI_MACHINE:-unknown}"
printf "${_c_b}*${_c_r}  Distro     : ${_c_g}%s${_c_r}\n" "${IMX93_BI_DISTRO:-unknown}"
printf "${_c_b}*${_c_r}  Built      : ${_c_g}%s${_c_r}\n" "${IMX93_BI_BUILT:-unknown}"
printf "${_c_b}*${_c_r}  Builder    : ${_c_g}%s${_c_r}\n" "${IMX93_BI_BUILDER:-unknown}"
printf "${_c_b}*${_c_r}  Host       : ${_c_g}%s%s${_c_r}\n" "$(hostname)" "${_ip:+ ($_ip)}"
printf "${_c_b}*${_c_r}  TTY        : ${_c_g}%s${_c_r}\n" "$(tty 2>/dev/null)"
printf "${_c_b}*${_c_r}  Login time : ${_c_g}%s${_c_r}\n" "$(date)"
printf "${_c_b}********************************************************${_c_r}\n"
printf '\n'

unset _c_b _c_y _c_g _c_r _ip
EOF
	chmod 0644 "${IMAGE_ROOTFS}${sysconfdir}/profile.d/imx93-banner.sh"

	# --- Ubuntu-style colorized interactive shell (prompt + ls/grep) -------
	cat > "${IMAGE_ROOTFS}${sysconfdir}/profile.d/imx93-color.sh" <<'EOF'
# IMX93-CUSTOM: Ubuntu-style colored prompt + ls/grep colors.
case "$-" in *i*) : ;; *) return 2>/dev/null || exit 0 ;; esac

if command -v dircolors >/dev/null 2>&1; then
	eval "$(dircolors -b)"
	alias ls='ls --color=auto'
	alias grep='grep --color=auto'
	alias fgrep='fgrep --color=auto'
	alias egrep='egrep --color=auto'
fi
alias ll='ls -alF'
alias la='ls -A'
alias l='ls -CF'

if [ -n "$BASH_VERSION" ]; then
	if [ "$(id -u)" -eq 0 ]; then
		PS1='\[\033[01;31m\]\u@\h\[\033[00m\]:\[\033[01;34m\]\w\[\033[00m\]\$ '
	else
		PS1='\[\033[01;32m\]\u@\h\[\033[00m\]:\[\033[01;34m\]\w\[\033[00m\]\$ '
	fi
fi
EOF
	chmod 0644 "${IMAGE_ROOTFS}${sysconfdir}/profile.d/imx93-color.sh"

	# No static /etc/motd -- see the header comment above. Remove any stale
	# copy an earlier build of this class may have left in place.
	rm -f "${IMAGE_ROOTFS}${sysconfdir}/motd"
}
