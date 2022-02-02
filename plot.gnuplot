set xlabel "wallet balance (single utxo) / ada"
set ylabel "fee / ada"
set title "Fee balancing small plutus tx"
set datafile separator ","
set terminal pdf size 7,5 background rgb 'white';
set output "balancingPlutusTx.pdf"

set linetype 1 lc rgb 'red'
set linetype 2 lc rgb '#111111'

plot \
  "lib/shelley/balanceTxGoldens/fee_at_low_balances/actual" \
    using 1:2 with lines ls 1 title "actual",\
  "lib/shelley/balanceTxGoldens/fee_at_low_balances/golden" \
    using 1:2 with lines ls 2 title "expected"
