PREFIX=gavriushov-09

for NUMBER in 1 2; do
  yc compute instance delete "$PREFIX-app-$NUMBER"
done

yc vpc subnet delete "$PREFIX-subnet"
yc vpc network delete "$PREFIX-net"
