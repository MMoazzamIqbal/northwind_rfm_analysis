CREATE OR REPLACE VIEW rfm_analysis AS (
WITH main_columns AS (
    -- Step 1: Aggregating base order data
    SELECT
        o.customer_id,
        o.order_id,
        o.order_date,
        SUM(od.unit_price * od.quantity * (1 - od.discount)) AS order_revenue,
        MAX(o.order_date) OVER () AS max_dataset_date
    FROM orders o
    JOIN order_details od 
        ON o.order_id = od.order_id
    GROUP BY 
        o.customer_id,
        o.order_id,
        o.order_date
),

durations_and_weights AS (
    -- Step 2: Calculating order durations and order weights
    SELECT
        customer_id,
        order_revenue,
        order_date,
        max_dataset_date,
        order_date - LAG(order_date) OVER (
            PARTITION BY customer_id 
            ORDER BY order_date
        ) AS order_duration, -- Calculating the duration between consecutive orders

        ROW_NUMBER() OVER (
            PARTITION BY customer_id 
            ORDER BY order_date
        ) AS order_weight -- Assigning larger weights to more recent orders
    FROM main_columns
),

raw_rfm AS (
    -- Step 3: Aggregating raw RFM metrics
    SELECT
        customer_id,
        SUM(order_revenue)::decimal(20,2) AS raw_monetary,
        COUNT(*) AS raw_frequency,
        max_dataset_date - MAX(order_date) AS raw_recency, -- Calculating recency from the latest dataset date

        SUM(order_duration * order_weight) 
            / NULLIF(
                SUM(
                    CASE 
                        WHEN order_duration IS NOT NULL 
                        THEN order_weight 
                    END
                ), 
                0
            ) AS avg_order_duration_customer
            -- Calculating the weighted average order duration as (x*w)/sum(w)

    FROM durations_and_weights
    GROUP BY 
        customer_id,
        max_dataset_date
),

-- Step 3.5: Calculating the global median recency
global_stats AS (
    SELECT
        PERCENTILE_CONT(0.5) WITHIN GROUP (
            ORDER BY raw_recency
        ) AS global_median_recency
        -- Calculating the global median recency for later segmentation

    FROM raw_rfm
),

dense_ranks AS (
    -- Step 4: Calculating dense ranks and the recency ratio
    SELECT
        r.*,
        g.global_median_recency,

        DENSE_RANK() OVER (
            ORDER BY r.raw_monetary DESC
        ) AS monetary_rank,

        DENSE_RANK() OVER (
            ORDER BY r.raw_frequency DESC
        ) AS frequency_rank,

        r.raw_recency::numeric 
            / NULLIF(r.avg_order_duration_customer, 0) AS recency_ratio
            -- Comparing recency with each customer's purchasing behavior

    FROM raw_rfm r
    CROSS JOIN global_stats g
),

fm_scores AS (
    -- Step 5: Calculating monetary and frequency scores
    SELECT
        *,
        DENSE_RANK() OVER (
            ORDER BY recency_ratio ASC NULLS LAST
        ) AS recency_rank,

        NTILE(5) OVER (
            ORDER BY monetary_rank DESC
        ) AS monetary_score,

        NTILE(5) OVER (
            ORDER BY frequency_rank DESC
        ) AS frequency_score
        -- Dividing customers into five score groups from 1 to 5

    FROM dense_ranks
),

rfm_scores AS (
    -- Step 6: Calculating recency scores
    SELECT
        customer_id,
        raw_monetary,
        raw_frequency,
        raw_recency,
        global_median_recency,
        avg_order_duration_customer,
        recency_ratio,
        monetary_score,
        frequency_score,

        CASE
            WHEN recency_ratio <= 0.5 THEN 5
            WHEN recency_ratio <= 1.0 THEN 4
            WHEN recency_ratio <= 1.5 THEN 3
            WHEN recency_ratio <= 2.0 THEN 2
            ELSE 1
        END AS recency_score
        -- Assigning recency scores

    FROM fm_scores
),

weighted_rfm AS (
    -- Step 7: Calculating the weighted RFM score
    SELECT
        *,
        ROUND(
            (monetary_score * 0.50) +
            (recency_score * 0.35) +
            (frequency_score * 0.15),
            2
        ) AS weighted_rfm_score
        -- Applying B2B weights: 50% monetary, 35% recency, and 15% frequency

    FROM rfm_scores
)

-- Step 8: Generating the final 2D segmentation output
SELECT
    r.customer_id,
    r.raw_monetary,
    r.raw_frequency,
    r.raw_recency,
    r.global_median_recency,
    r.recency_score,
    r.monetary_score,
    r.frequency_score,
    r.weighted_rfm_score,

    -- Applying the 2D segmentation matrix with a global median threshold
    CASE
        WHEN r.monetary_score >= 4
             AND (
                 r.recency_score >= 4
                 OR r.raw_recency <= r.global_median_recency
             )
            THEN 'Champions'

        WHEN r.monetary_score >= 4
             AND r.recency_score = 3
            THEN 'Loyal High-Value'

        WHEN r.monetary_score >= 4
             AND r.recency_score <= 2
            THEN 'At-Risk High-Value'

        WHEN r.monetary_score = 3
             AND (
                 r.recency_score >= 4
                 OR r.raw_recency <= r.global_median_recency
             )
            THEN 'Emerging'

        WHEN r.monetary_score <= 2
             AND r.raw_recency > r.global_median_recency
            THEN 'Lost'

        ELSE 'Middle'
    END AS segment, 
    -- Applying monetary and recency logic for B2B segmentation
 
    c.company_name
    -- Adding the customer name to the final output

FROM weighted_rfm r
LEFT JOIN customers c  
    ON r.customer_id = c.customer_id
    -- Adding customer information through the customer lookup

ORDER BY 
    r.weighted_rfm_score DESC,
    r.raw_monetary DESC
);

