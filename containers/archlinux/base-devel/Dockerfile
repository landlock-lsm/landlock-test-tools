# SPDX-License-Identifier: GPL-2.0
#
# Copyright © 2022-2024 Mickaël Salaün <mic@digikod.net>.

FROM archlinux:base-devel as common
RUN pacman -Sy
RUN pacman --noconfirm -S \
	git

ARG USER GROUP UID GID
RUN groupadd --gid $GID $GROUP && \
	useradd --uid $UID --gid $GID --create-home --shell /bin/bash $USER

FROM common as smatch
ARG USER
USER $USER
RUN git init /tmp/smatch
WORKDIR /tmp/smatch
ARG SMATCH_REF
RUN git remote add origin https://repo.or.cz/smatch.git && \
	git fetch --no-tags origin master && \
	git reset --hard $SMATCH_REF
RUN make -j$(nproc)

FROM common as target
RUN pacman --noconfirm -S \
	bc \
	clang \
	python \
	rsync

COPY --from=smatch /tmp/smatch/smatch /usr/bin/

ARG USER
USER $USER
ARG WORKTREE
WORKDIR "$WORKTREE"
ARG BASE_DIR
ENV PATH "$PATH:$BASE_DIR"

ENV O ".out-landlock_archlinux-base-devel"
CMD ["check-linux.sh", "all"]
