#!/bin/bash

# This script goes through the steps required by:
# https://github.com/96boards-hikey/tools-images-hikey960/blob/master/build-from-source/README-ATF-UEFI-build-from-source.md
#
# This assumes a Hikey960 v2 or later board, as there are special case for earlier hardware.

function clone_repos ()
{
	if [ ! -e repos ]; then
		mkdir repos
		pushd repos

		git clone https://github.com/ARM-software/arm-trusted-firmware -b integration
		git clone https://github.com/96boards-hikey/edk2 -b testing/hikey960_v2.5
		git clone https://github.com/96boards-hikey/OpenPlatformPkg -b testing/hikey960_v1.3.4
		git clone https://github.com/96boards-hikey/l-loader -b testing/hikey960_v1.2
		git clone https://git.linaro.org/uefi/uefi-tools
		git clone https://github.com/96boards-hikey/atf-fastboot
		git clone https://github.com/96boards-hikey/tools-images-hikey960

		pushd edk2
		ln -sf ../OpenPlatformPkg
		popd

		popd
	else
		echo "Skip fetching repos as already present"
	fi
}

function get_debian_images ()
{
	if [ ! -e debian ]; then
		mkdir debian

		pushd debian
		wget http://snapshots.linaro.org/96boards/hikey/linaro/debian/latest/boot-linaro-stretch-developer-hikey-*.img.gz
		wget http://snapshots.linaro.org/96boards/hikey/linaro/debian/latest/rootfs-linaro-stretch-developer-hikey-*.img.gz

		gunzip *.gz

		wget http://snapshots.linaro.org/96boards/reference-platform/components/uefi-staging/latest/hikey960/debug/prm_ptable.img
		mv prm_ptable.img prm_ptable_debian.img
		popd
	else
		echo "Skip fetching Debian images as already present"
	fi
}

function setup_environment ()
{
	# Build UEFI in DEBUG mode

	echo "Setup environment variables ..."

	set -x
	export BUILD_PATH=$PWD/repos

	export BUILD_OPTION=DEBUG

	# This assumes the aarch64-linux-gnu- toolchain is installed
	if [ -z $(which aarch64-linux-gnu-gcc) ]; then
		echo "Please make sure there is an aarch64-linux-gnu- toolchain in your path"
		exit 1
	fi

	export AARCH64_TOOLCHAIN=GCC5
	export UEFI_TOOLS_DIR=${BUILD_PATH}/uefi-tools
	export EDK2_DIR=${BUILD_PATH}/edk2
	export EDK2_OUTPUT_DIR=${EDK2_DIR}/Build/HiKey960/${BUILD_OPTION}_${AARCH64_TOOLCHAIN}
	set +x
}

function build_uefi ()
{
	echo "Building UEFI in $BUILD_OPTION mode"
	pushd ${EDK2_DIR}
	${UEFI_TOOLS_DIR}/uefi-build.sh -b ${BUILD_OPTION} -a ../arm-trusted-firmware hikey960
	popd
}

function build_base_firmware ()
{
	pushd ${BUILD_PATH}/l-loader

	ln -sf ${EDK2_OUTPUT_DIR}/FV/bl1.bin
	ln -sf ${EDK2_OUTPUT_DIR}/FV/bl2.bin
	ln -sf ${EDK2_OUTPUT_DIR}/FV/fip.bin
	ln -sf ${EDK2_OUTPUT_DIR}/FV/BL33_AP_UEFI.fd

	make hikey960 recovery.bin

	popd
}

function setup_serial_console ()
{
	# Install ser2net as minicom does not display the UEFI menu properly (apparently)
	sudo apt-get install ser2net

	# Fixup the config file, if it hasn't been done already
	if [ $(grep "2004:telnet:0:/dev/ttyUSB0:115200 8DATABITS NONE 1STOPBIT banner" /etc/ser2net.conf | wc -l) = 0 ]; then
		echo "2004:telnet:0:/dev/ttyUSB0:115200 8DATABITS NONE 1STOPBIT banner" | sudo tee -a /etc/ser2net.conf
	fi
}

function flash_base_firmware ()
{
	echo "Generate and flash base firmware images"

	pushd ${BUILD_PATH}/tools-images-hikey960

	ln -sf ${BUILD_PATH}/l-loader/l-loader.bin
	ln -sf ${BUILD_PATH}/l-loader/fip.bin
	ln -sf ${BUILD_PATH}/l-loader/recovery.bin

	echo "Making a backup of any existing file named 'config' ..."
	mv config config.BAK

	echo "./hisi-sec_usb_xloader.img 0x00020000" > config
	echo "./hisi-sec_uce_boot.img 0x6A908000" >> config
	echo "./recovery.bin 0x1AC00000" >> config

	echo ""
	echo "This step requires the removal of the modemmanager package, if present, if this is needed"
	echo "on this system, please make sure to reinstall it once flashing is complete"
	echo ""

	sudo apt-get remove --purge modemmanager

	# The information on dip switch configuration for recovery/fastboot comes from:
	# https://github.com/96boards-hikey/tools-images-hikey960/blob/master/README.md
	echo "Prepare to enter recovery mode."
	echo "Please power off your Hikey960 board and set the boot switches to:"
	echo "		Switch 1: Auto Power Up: ON"
	echo "		Switch 2: Boot Mode    : ON"
	echo "		Switch 3: Ext. Boot    : OFF"
	echo ""
	echo "Power on your board and connect the serial console USB (connected to the mezzanine) to your PC ..."
	read -n 1 -s -r -p "Hit any key to continue ..."
	echo "Now connect a USB-C cable to the OTG port on the Hikey960 and connect it to your PC ..."
	read -n 1 -s -r -p "Hit any key to continue flashing base firmware ... "

	sudo ./hikey_idt -c config

	popd
}

function flash_fastboot_images ()
{

#	Looking at the instructions, I am not entirely sure we need to be in fastboot
#	mode. Let's try it with the recovery mode switches and see how we go. It might
#	be that we have to display a similar prompt clearing both recovery and
#	fastboot switches to enable a normal boot.


	echo "Update images ..."

	pushd ${BUILD_PATH}/tools-images-hikey960

	expect ${BUILD_PATH}/../hikey960_fastboot.expect > /dev/null

	#Flash bootloader images
	sudo fastboot flash ptable ${BUILD_PATH}/../debian/prm_ptable_debian.img
	sudo fastboot flash xloader hisi-sec_xloader.img
	sudo fastboot flash fastboot l-loader.bin
	sudo fastboot flash fip fip.bin
	#Flash OS images
	sudo fastboot flash boot ${BUILD_PATH}/../debian/boot-linaro-stretch-developer-hikey-*.img
	sudo fastboot flash system ${BUILD_PATH}/../debian/rootfs-linaro-stretch-developer-hikey-*.img
	popd
	echo "Please power off your Hikey960 board and set the boot switches to normal mode:"
	echo "		Switch 1: Auto Power Up: ON"
	echo "		Switch 2: Boot Mode    : OFF"
	echo "		Switch 3: Ext. Boot    : OFF"
	echo ""
	echo "Remove the USB-C cable from PC and Power on your board ..."
}

clone_repos
get_debian_images
setup_environment
build_uefi
build_base_firmware
setup_serial_console
flash_base_firmware
flash_fastboot_images
