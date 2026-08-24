show() {
  echo "fn#=$# fn1=$1"
  for a in "$@"; do echo "fn[$a]"; done
}
set -- "a b" c
echo "top#=$#"
for a in "$@"; do echo "top[$a]"; done
show p q
echo "back:$1"
