i=0
while [ $i -lt 3 ]; do
  echo "n=$i"
  i=$((i + 1))
done > nums.txt
cat nums.txt
