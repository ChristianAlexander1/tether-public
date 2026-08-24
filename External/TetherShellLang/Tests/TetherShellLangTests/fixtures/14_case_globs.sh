check() {
  case "$1" in
    [a-z]*) echo "lower:$1" ;;
    [A-Z]*) echo "upper:$1" ;;
    *[0-9]) echo "digit-end" ;;
    *) echo "other" ;;
  esac
}
check hello
check World
check abc9
check "---9"
check "---"
