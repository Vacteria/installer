#!/bin/sh

usage()
{
	cat << EOF
	
 -a, --all        Running al nede process to make boot cdrom
 -r, --ramfs      Only create initramfs file
 -i, --installer  Only create installer image
 -c, --cdrom      Only create a cdrom iso image
 -p, --profile    Create a software profile using a package list
 -h, --help       Show this help and exit

EOF
}

create_ramfs()
{
	[ -f cdrom/boot/boot.img ] && rm -f cdrom/boot/boot.img
	
	mkdir -p cdrom/boot
	mkramfs --create --outfile="cdrom/boot/boot.img" --type="installer" --kernel="${KERNEL}" --noclean --verbose
}

copy_isolinux()
{
	mkdir -p cdrom/isolinux
	for f in isolinux.bin vesamenu.c32
	do
		[ -f cdrom/isolinux/${f} ] && rm -f cdrom/isolinux/${f}
		if [ ! -f cdrom/isolinux/${f} ]
		then
			cp -a /usr/lib/syslinux/${f} cdrom/isolinux
		fi
	done

	if [ ! -f cdrom/boot/vmlinuz ]
	then
		[ -f cdrom/boot/vmlinuz ] && rm -f cdrom/boot/vmlinuz
		cp -avf /boot/vmlinuz-${KERNEL} cdrom/boot/vmlinuz
	fi
}

create_iso()
{
	[ -f "${ISOFILE}" ] && rm -f "${ISOFILE}"
	
	if [ ! -f cdrom/boot/vmlinuz ]
	then
		echo "Unable to locate any usable kernel for live system."
		exit 1
	elif [ ! -f cdrom/boot/boot.img ]
	then
		echo "Missing live boot initramfs file"
		exit 1
	fi
	
	xorrisofs \
		-rock -joliet \
		-input-charset utf8 \
		-o "${ISOFILE}" \
		-volid "${VOLUME}" \
		-publisher "${VENDOR}" \
		-b isolinux/isolinux.bin \
		-c isolinux/boot.cat \
		-no-emul-boot \
		-boot-load-size 4 \
		-boot-info-table \
		-isohybrid-mbr /usr/lib/syslinux/isohdpfx.bin \
		-partition_offset 16 \
		"${PWD}/cdrom"
}

make_all()
{
	create_ramfs
	copy_isolinux
	create_iso
}

create_installer()
{
	local LIST NAME DEST MISSING APPEND I P F

	LIST="catalogs/installer.txt"
	NAME="installer"
	DEST="$( trim_slashes "${PWD}/${NAME}" )"

	if [ -z "${REPO}" ]
	then
		echo "Unable to get a suitable repo directory"
		exit 1
	fi

	if [ -z "${LIST}" ]
	then
		echo "Unable to get a suitable list file"
		exit 1
	fi

	if [ "${DEST}" == "/" ]
	then
		echo "Unable to use rootfs as destiny directory. Are you crazy ?"
		exit 1
	fi

	case ${DEST} in
		. | $(trim_slashes "${PWD}") )
			echo "Unable to use current directory as destiny. Are you crazy ?"
			exit 1
		;;
	esac
	
	if [ -d "${DEST}" ]
	then
		for V in proc sys dev
		do
			if mountpoint -q ${DEST}/${V}
			then
				umount -l ${DEST}/${V}
			fi
		done
		rm -rf "${DEST}"
	fi
	[ ! -d "${DEST}" ] && mkdir -p "${DEST}"

	if [ ! -f "${DEST}/var/vpm/packages.db" ]
	then
		vpm --dbase --root=${DEST}
	fi
	
	for I in $(grep -Ev -- '^($|#)' ${LIST})
	do
		MATCH="$(find ${REPO} -type f -name "*.vpm" | grep -E -- "${I}-[[:digit:]].*-(${ARCH}|noarch).*")"
		if [ -z "${MATCH}" ]
		then
			MISSING+=(${I})
			continue
		fi

		for P in ${MATCH}
		do
			F="${P##*/}"
			if [ "${F//-[0-9]*}" == "${I}" ]
			then
				APPEND+=(${P})
			fi
		done
	done

	if (( ${#MISSING[@]} > 0 ))
	then
		cat << EOF
The next patterns have not matches
${MISSING[@]}
Unable to continue
EOF
		exit 1
	fi
	
	ARGS="--norundeps --noscript --notriggers"
	for A in ${APPEND[@]}
	do
		vpm --install --root=${DEST} ${ARGS} ${A}
	done

	cp -a ${DEST}/etc/rc.conf.d/locales{,.orig}
	cat > ${DEST}/etc/rc.conf.d/locales << EOF
es_ES.UTF-8 UTF-8
es_ES ISO-8859-1
en_US.UTF-8 UTF-8
en_US ISO-8859-1
EOF

	for A in ${APPEND[@]}
	do
		F="${A##*/}"
		if [ -f ${DEST}/var/vpm/setup/${F%%.vpm} ]
		then
			vpm --config --root=${DEST} ${F}
		fi
	done
	
	for F in ${DEST}/etc/rc.d/*
	do
		chroot ${DEST} insserv -rf ${F##*/}
		chroot ${DEST} insserv -f ${F##*/}
	done
	
	for D in proc sys dev
	do
		if mountpoint -q ${DEST}/${D}
		then
			umount ${DEST}/${D}
		fi
	done
	
	mv -f ${DEST}/etc/rc.conf.d/{locales.orig,locales}
	
	ls -1 ${DEST}/usr/share/locale/ | \
	while read D 
	do
		case ${D} in
			es | en | es_* | locale.alias ) continue ;;
		esac
		
		rm -rf ${DEST}/usr/share/locale/${D}
	done
	rm -rf ${DEST}/usr/share/doc/*
	find ${DEST}/usr/share/man  -type f -print0 | xargs -r0I{} rm -f {}
	find ${DEST}/usr/share/info -type f -print0 | xargs -r0I{} rm -f {}
	
	[ -f cdrom/images/installer.sqf ] && rm -f cdrom/images/installer.sqf
	mksquashfs ${DEST}/ cdrom/images/installer.sqf -comp xz
}

create_profile()
{
	LIST="${1}"
	LIST_FILE="${1##*/}"
	DEST="${LIST_FILE%.txt}"
	
	if [ -z "${REPO}" ]
	then
		echo "Unable to get a suitable repo directory"
		exit 1
	fi

	if [ -z "${LIST}" ]
	then
		echo "Unable to get a suitable list file"
		exit 1
	fi
	
	for I in $(grep -Ev -- '^($|#)' ${LIST})
	do
		MATCH="$(find ${REPO} -type f -name "*.vpm" | grep -E -- "${I}-[[:digit:]].*-(${ARCH}|noarch).*")"
		if [ -z "${MATCH}" ]
		then
			MISSING+=(${I})
			continue
		fi

		for P in ${MATCH}
		do
			F="${P##*/}"
			if [ "${F//-[0-9]*}" == "${I}" ]
			then
				D="${P%/*}"
				B="${P##*/}"
				[ ! -d "${DEST}/${D##${REPO}/}" ] && mkdir -p "${DEST}/${D##${REPO}/}"
				cp -af ${P} ${DEST}/${D##${REPO}/}/${B}

				APPEND+=(${P})
			fi
		done
	done

	if (( ${#MISSING[@]} > 0 ))
	then
		cat << EOF
The next patterns have not matches
${MISSING[@]}
Unable to continue
EOF
		exit 1
	fi
	
	printf '%s\n' ${APPEND[@]#${REPO}/} > cdrom/setup/profiles/${LIST##*/}
	mksquashfs ${DEST} cdrom/images/${DEST}.sqf
}

get_kernel()
{
	local OUT
	
	OUT="$(uname -r)"
	
	[ -z "${OUT}" ] && return 1
	
	printf "${OUT}"
	
	return 0
}

get_arch()
{
	local OUT
	
	case "$(uname -m)" in
		i?86 ) OUT="x32" ;;
		x86_*) OUT="x64" ;;
	esac
	
	[ -z "${OUT}" ] && return 1
	
	printf "${OUT}"
	
	return 0
}

trim_slashes()
{
	echo "${@}" |tr -s '/'
}

# Need modules
# zram loop squashfs fuse exportfs aufs fat vfat msdos isofs crc-itu-t udf cdrom scsi_mod
# sd_mod sr_mod libata ata_generic ata_piix
# usb_common usbcore hid usbhid hid_generic uas usb_storage ohci_hcd ehci_hcd

. ${PWD}/config || exit 1

MAKE_ALL=""
ONLY_RAM=""
ONLY_INS=""
ONLY_CDR=""
ONLY_PRO=""

SHORT="aricph"
LONG="all,ramfs,installer,cdrom,profile,help"
GLOBAL="$(getopt --options ${SHORT} --longoptions ${LONG} --name mkmodule -- "${@}")"
[ "$?" != "0" ] && exit >&2

eval set -- ${GLOBAL}

while true
do
	case ${1} in
		-a|--all       ) MAKE_ALL="1"  ;;
		-r|--ramfs     ) ONLY_RAM="1"  ;;
		-i|--installer ) ONLY_INS="1"  ;;
		-c|--cdrom     ) ONLY_CDR="1"  ;;
		-p|--profile   ) ONLY_PRO="1"  ;;
		-h|--help      ) usage ; exit 0;;
		-- ) shift ; break             ;;
	esac
	shift
done

KERNEL="${KERNEL:-$(get_kernel)}"
ARCH="${ARCH:-$(get_arch)}"
ISONAME="vct${ARCH#x}"
CODENAME="${CODENAME:-Unknow}"
RELEASE="${RELEASE:-1.0}"
VENDOR="${VENDOR:-Vacteria}"
ISOFILE="${ISONAME}-${CODENAME}-${RELEASE}.iso"

case "${ARCH}" in
	x32|x64) true ;;
	*          )
		echo "Unsupported ${ARCH}"
		exit 1
	;;
esac

if [ "${MAKE_ALL}" == "1" ]
then
	make_all
elif [ "${ONLY_RAM}" == "1" ]
then
	create_ramfs
elif [ "${ONLY_INS}" == "1" ]
then
	create_installer
elif [ "${ONLY_CDR}" == "1" ]
then
	create_iso
elif [ "${ONLY_PRO}" == "1" ]
then
	create_profile ${@}
fi
