FROM archlinux
RUN pacman -Syyu --noconfirm dpkg diffutils
WORKDIR /pwd
