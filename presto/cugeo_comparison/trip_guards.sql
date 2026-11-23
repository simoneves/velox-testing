-- Spatial functions over every trip under IF and CASE guards whose
-- conditions test ordinary BIGINT columns, under a global aggregation. (The
-- fare and tip columns are DECIMAL, which cuGeo's nodes do not carry yet.)
SELECT count(*) AS trips,
       sum(IF(t_vehiclekey % 2 = 0, ST_Distance(ST_GeomFromBinary(t_pickuploc), ST_GeomFromBinary(t_dropoffloc)))) AS even_vehicle_distance,
       max(CASE WHEN t_custkey > 1000 THEN ST_XMin(ST_GeomFromBinary(t_dropoffloc)) END) AS later_customer_max_x
FROM trip
