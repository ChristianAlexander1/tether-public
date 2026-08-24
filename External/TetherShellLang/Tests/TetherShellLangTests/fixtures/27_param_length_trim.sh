s=hello
echo "${#s}"
path=/usr/local/bin/tool
echo "${path##*/}"
echo "${path#*/}"
echo "${path%/tool}"
f=archive.tar.gz
echo "${f%.*}"
echo "${f%%.*}"
