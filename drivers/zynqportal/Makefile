obj-m += zynqportal.o

export KROOT=$(DEVICE_XILINX_KERNEL)

DRIVER_VERSION=$(shell git log -n 1 --oneline -- zynqportal.c zynqportal.h ../../cpp/dmaSendFd.h)

ccflags-y := -I$(src)/../portalmem -I$(src)/../../cpp -I$(src)/../../generated/cpp -D DRIVER_VERSION_RAW="$(DRIVER_VERSION)"

default: zynqportal.ko
	echo "$(DRIVER_VERSION)"
	cp zynqportal.ko ~/adb_scripts/

zynqportal.ko: zynqportal.h zynqportal.c
	echo "$(DRIVER_VERSION)"
	@$(MAKE) ARCH=arm CROSS_COMPILE=arm-none-linux-gnueabi- -C $(KROOT) xilinx_zynq_portal_defconfig
	@$(MAKE) ARCH=arm CROSS_COMPILE=arm-none-linux-gnueabi- -C $(KROOT) oldconfig
	@$(MAKE) -j 8 ARCH=arm CROSS_COMPILE=arm-none-linux-gnueabi- -C $(KROOT) zImage
	@$(MAKE) ARCH=arm CROSS_COMPILE=arm-none-linux-gnueabi- -C $(KROOT) M=$(PWD) DRIVER_VERSION="$(DRIVER_VERSION)" modules

clean:
	@$(MAKE) ARCH=arm CROSS_COMPILE=arm-none-linux-gnueabi- -C $(KROOT) M=$(PWD) clean
