# SPDX-License-Identifier: GPL-2.0
#
# Copyright © 2022-2024 Mickaël Salaün <mic@digikod.net>.

# Container-specific configuration: /etc/apt/apt.conf.d/docker-clean
FROM debian:sid as common
RUN apt update
RUN apt install --yes --no-install-recommends \
	gcc \
	git \
	make

ARG USER GROUP UID GID
RUN groupadd --gid $GID $GROUP && \
	useradd --uid $UID --gid $GID --create-home --shell /bin/bash $USER

FROM common as smatch
RUN apt install --yes --no-install-recommends \
	ca-certificates \
	libdbd-sqlite3-perl \
	libsqlite3-dev \
	libssl-dev \
	libtry-tiny-perl

ARG USER
USER $USER
RUN git init /tmp/smatch
WORKDIR /tmp/smatch
ARG SMATCH_REF
RUN git remote add origin https://repo.or.cz/smatch.git && \
	git fetch --depth 1 origin $SMATCH_REF && \
	git reset --hard FETCH_HEAD
RUN make -j$(nproc)

FROM common as target
RUN apt install --yes --no-install-recommends \
	bc \
	bison \
	clang-format-16 \
	flex \
	gcc \
	git \
	iproute2 \
	libc6-dev \
	libcap-dev \
	rsync \
	sparse \
	systemd \
	systemd-sysv

COPY --from=smatch /tmp/smatch/smatch /usr/bin/

ARG USER
USER $USER
ARG WORKTREE
WORKDIR "$WORKTREE"
ARG BASE_DIR
ENV PATH "$PATH:$BASE_DIR"

ENV O ".out-landlock_debian-sid"
CMD ["check-linux.sh", "all"]
