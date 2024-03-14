# Landlock test tools

This repository is a collection of scripts and configurations to easily test
various Landlock kernels thanks to User-Mode Linux (UML).

To make tests quick, interesting kernels are stored in kernels/artifacts and
built with the kernels/make-uml.sh script.

uml-run.sh can be used to launch an UML kernel with an init test script.

## docker-run

Build a container to build the kernel, samples, tests and check everything for Landlock.

Required installed and configured software: docker and optionally docker-buildx.

```shell
git clone https://git.kernel.org/pub/scm/linux/kernel/git/torvalds/linux.git
cd linux
.../docker-run.sh debian/sid
```

## check-linux

Build the kernel, samples, tests and check everything for Landlock.

```shell
cd linux
.../check-linux.sh build kselftest kunit
```

## rust-landlock

test-rust.sh can be used to test the Landlock crate against a specific kernel
version:
```shell
cd rust-landlock
.../test-rust.sh linux-6.1 2
```
