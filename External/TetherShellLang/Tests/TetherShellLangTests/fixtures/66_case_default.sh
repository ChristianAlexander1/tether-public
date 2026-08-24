report() {
  case "$1" in
    y|yes) echo "affirmative" ;;
    n|no) echo "negative" ;;
    "") echo "empty-input" ;;
    *) echo "unknown:$1" ;;
  esac
}
report yes
report no
report ""
report maybe
