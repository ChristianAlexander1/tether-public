if true; then
  echo "one"
  echo "two"
fi > block.txt
cat block.txt
{ echo "three"; echo "four"; } >> block.txt
cat < block.txt
