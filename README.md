# rho-contracts




## Gotchas and Notes

we use fixed notional instead of float notional bc it doesnt compound. allows us to take off the books more easily.
fixedNotionalPaying ~= floatNotionalReceiving, and fixedNotionalReceiving ~= floatNotionalPayingFloat
```

		vars.parBlocksReceivingFloatNew = _sub(parBlocksReceivingFloat, _mul(fixedNotionalPaying, accruedBlocks));
		vars.parBlocksPayingFloatNew = _sub(parBlocksPayingFloat, _mul(fixedNotionalReceiving, accruedBlocks));

```
