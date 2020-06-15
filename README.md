# rho-contracts




## Gotchas and Notes

we use fixed notional instead of float notional bc it doesnt compound. allows us to take off the books more easily.
notionalPayingFixed ~= notionalReceivingFloat, and notionalReceivingFixed ~= notionalPayingFloatFloat
```

		vars.parBlocksReceivingFloatNew = _sub(parBlocksReceivingFloat, _mul(notionalPayingFixed, accruedBlocks));
		vars.parBlocksPayingFloatNew = _sub(parBlocksPayingFloat, _mul(notionalReceivingFixed, accruedBlocks));

```
