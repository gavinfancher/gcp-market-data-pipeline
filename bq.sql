SELECT 
  symbol, 
  date,
  ARRAY_AGG(open ORDER BY timestamp LIMIT 1)[OFFSET(0)] AS open,
  MAX(high) AS high,
  MIN(low) AS low,
  ARRAY_AGG(close ORDER BY timestamp DESC LIMIT 1)[OFFSET(0)] AS close,
  SUM(volume) AS volume 
FROM `gcp-market-data-pipeline.market_data.minute_bars`
WHERE
  date = "2026-10-01" AND
  TIME(timestamp, "America/New_York") BETWEEN "09:30:00" AND
  "15:59:00"
GROUP BY
  symbol,
  date
ORDER BY symbol