# Monza build container: every toolchain and build dependency for the
# Arduino VENTUNO Q (QCS8275 / Monaco) open boot stack lives here, never on
# the host.
#
# The cross compilers are not baked in: "make -f monza.mk toolchains"
# downloads them into the bind-mounted workspace so they persist across
# container runs. The distro cross GCC is the fallback for TF-A when the
# downloaded toolchain mixes badly with the host LTO plugins.
FROM ubuntu:24.04

ENV DEBIAN_FRONTEND=noninteractive
ENV LANG=C.UTF-8
ENV LC_ALL=C.UTF-8

# The Ubuntu mirrors are round-robin and can briefly disagree with their
# index; retry instead of failing the whole image.
RUN for try in 1 2 3 4 5; do \
	apt-get update && apt-get install -y --no-install-recommends \
	ca-certificates curl wget git openssh-client rsync \
	build-essential make cmake ninja-build meson pkg-config \
	gcc-aarch64-linux-gnu g++-aarch64-linux-gnu \
	python3 python3-dev python3-venv python3-pip python3-setuptools \
	python3-pyelftools python3-cryptography python3-pkg-resources \
	bc bison flex libssl-dev libelf-dev dwarves libgnutls28-dev \
	cpio unzip zip xz-utils bzip2 gzip zstd lz4 tar patch file \
	device-tree-compiler uuid-dev acpica-tools nasm \
	libncurses-dev gawk perl sed diffutils findutils kmod \
	bsdextrautils debianutils openssl bash-completion \
	mtools dosfstools systemd-ukify xxd \
	libxml2 libxml2-dev libzip-dev libusb-1.0-0-dev help2man \
	sudo procps less vim-tiny locales \
	&& break; sleep 30; done \
	&& command -v ukify \
	&& rm -rf /var/lib/apt/lists/*

# bsdextrautils provides hexdump, needed by the arm64 EFI_ZBOOT rule;
# libgnutls28-dev and xxd are needed by U-Boot's host tools and env build;
# debianutils provides which, needed by the buildroot dependency check.

RUN curl -fsSL https://storage.googleapis.com/git-repo-downloads/repo \
	-o /usr/local/bin/repo && chmod 0755 /usr/local/bin/repo

# The workspace is bind-mounted and owned by the invoking uid.
RUN git config --system safe.directory '*' \
	&& git config --system advice.detachedHead false

WORKDIR /monza/src/build
