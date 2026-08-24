echo data > a.txt
echo data > b.txt
echo data > c.md
for f in *.txt; do
  echo "found:$f"
done
echo "quoted *.md"
echo "no-match:" *.zzz
