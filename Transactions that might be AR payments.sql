/* =====
-- Transactions that might be for an Outstanding Invoice (Updated 1/30/26 - MattC)

The previous version of this report ONLY flagged transactions w/ an Amount that equaled an Open Invoice's TOTAL
THIS version uses a SCORING model to identify a RANGE of 'likely matches' based on NUMEROUS 'flags' or 'Signals'

Process:
   1 - Looks in Transaction Details table and 'flags' any tran w/ SOME element (Signal) that matches an Open Invoice. Signals we check for:
         - If the tran DESCRIPTION lists the Invoice # of an open invoice OR contains ANY 'FIxxxxxx' Inv#
         - If one or more FOAPAL codes match one or more codes from an open Invoice
         - If the tran DATE is within a 'reasonable' timeframe of the Invoice (see 'Filtering Rules' note below)
         - If the tran AMOUNT matches an amount from an open invoice
   2 - Compares each 'flagged' transaction to each Open Invoice and calculates a 'Confidence Score' for each based on its number of matching Signals
   3 - Final report is sorted:
         - Most recent Transaction first
         - for each transaction, any Open Invoices that it COULD be a match for are listed in order of BEST match to least likely

   Notes:
      - This report computes a score for each and EVERY transaction that matches at least TWO of the above signals from ANY open Invoice
         - This is necessary bc it's IMPOSSIBLE to predict which 'piece' went wrong and caused something to get misplaced. And it can (and DOES) differ from one transaction to the next
         - Finding matches on ANY two signals DOES result in MANY 'false positives', HOWEVER, these are easily weeded out by setting a 'threshold' for what score we consider a 'likely match' vs what can be 'safely excluded'
         - Threshold is set in the 'MatchedResults' cte 

      - The previous version only compared transactions AMOUNT and ONLY at the INVOICE level. THIS report compares transactions to all the above Signals and ALSO at MULTIPLE levels:
         - Invoice level
         - FUND level total: in case an Invoice is split between MANY Fund codes and a pmt is only for ONE of the funds listed on the invoice
         - FOAPAL level: in case there are multiple INDEX codes (or others like Org, Locn, Prog, etc) and a pmt is only for one of THOSE
         - Outstanding Balance: if a payments against an Invoice have been made in INSTALLMENTS or if other Adjustments have been made, this report now checks if a tranAmount matches just the REMAINING amount

      - All that said, it is CRUCIAL to understand that Transactions and Invoices are compared to each other and matched at the FOAPAL LINE level
         - If an Inv listed as a match has only ONE FOAPAL line, the transaction is effectively a match for the entire invoice (ie - FOAPAL level = FUND level = INVOICE level)
         - If an Inv listed as a match has MORE than one FOAPAL line, the transaction is a match for JUST that FOAPAL LINE of that invoice

      - The final report already contains a LOT of info per UNIQUE row. On TOP of that,
         -- Because the Transactions table is JOINED on ANY match at the FOAPAL line level: 
               - A duplicate row of TRANSACTION details is displayed for EVERY matching invoice, AND
               - A duplicate row of INVOICE details is displayed for each matching FOAPAL line from a matching Inv
         -- While perfectly logical to robots such as myself, this QUICKLY becomes overwhelming to mere mortals
         -- In an attempt to make things more clear and understandable, several columns are computed and used SOLELY to help arrange the data in a more 'visually digestible' format
         -- These 'visualization' columns do not affect the FUNCTION of the report; they exist ONLY for (but are essential to) its PRESENTATION
   
   SUMMARY: 
      - the previous 'ONLY return matches for these EXACT conditions' query was rigid and broke ANY time there was an exception to a filter rule
      - This new method is MUCH more flexible and is CRAZY adjustable 
   
   Filtering Rules are based on following rationale:
      -- any tran that might be a pmt SHOULD be either a JV (JE16) or go through the Cashier's Office (RCP)
      -- misplaced pmts WON'T be in {Excluded_AR_Accounts} (per Gavin & Suzanne)
      -- Payments are received no earlier than 2 weeks prior to the Inv date
         - Previous version used ON or AFTER Invoice date but in RARE instances pmts ARE received BEFORE an Inv has been created
         - This now catches those upto 2 wks prior. Anything EARLIER than that is excluded
      -- any mistyped Inv # contains at LEAST 5 digits. ie - the query will flag 'FI00o123' as a probable Inv # but will exclude 'FIooo123'
      -- any tran that IS a misplaced pmt SHOULD match at least TWO signals
      -- All the above can be adjusted as needed

========== */

-- 1) Get Info from JUST the Open Invoices to match transactions details against

-- Retrieves all posted invoices w/ an outstanding balance > 0 and displays their accounting details at the FOAPAL string level
-- This CTE is used in MULTIPLE other queries and NOT to be updated w/o updating it in ALL OTHER locations as well
WITH OutstandingInvoices AS (
   SELECT
      -- INV level details
      bal.TXTINVOICE,
      bal.CTRCUSTOMER,
      bal.TXTCUSTOMERNAME,
      bal.DATINVOICEDATE,
      bal.INVAMOUNT,
      bal.OUTSTANDING,
      bal.PAYMENTS,
      bal.ADJUSTMENTS,
      bal.TXTBATCHID,
      bal.TXTDEPT,
      
      i.TXTCREATED, -- inv CREATOR
      
      -- FUND level details 
      COUNT(DISTINCT fndln.FUND) OVER (
         PARTITION BY bal.TXTINVOICE) AS FUND_COUNT, -- 'visualization column' used to hide duplicate details for Invoices w/ more than one FUND 
      DENSE_RANK() OVER (
         PARTITION BY bal.TXTINVOICE 
         ORDER BY fndln.FUND) AS FUNDLINE, -- assigns a row number to each unique FUND per inv to make it more apparent that an inv HAS more than one
      fndln.FUND,
      fndln.PERFUNDTOTAL, -- SUMS inv FOAPAL lines by unique FUND Code to show how much of the inv total is owed to each Fund
      fndln.FUND||TO_CHAR(fndln.PERFUNDTOTAL) AS FUNDKEY, -- for use in the AR Payments to Enter and Possible AR Payments reports
      
      -- FOAPAL level details
      fpln.CTRINVA as FoapalLineID, -- used in Partition/Group sorting and for matching Debits to Credits later
      fpln.ACCI,
      fpln.ORGN, 
      fpln.ACCT, 
      fpln.PROG, 
      fpln.ACTV, 
      fpln.LOCN,
      fpln.CURAMOUNT AS FOAPALlineTotal,
      ROW_NUMBER() OVER (
         PARTITION BY bal.TXTINVOICE, fndln.FUND 
         ORDER BY fpln.ORGN, fpln.ACCT, fpln.PROG, fpln.ACTV,  fpln.LOCN) AS FOAPALline -- assigns number to each unique FOAPAL line. Used for 'visual decluttering' in Outstanding Invoices reporting page

   FROM {Invoices Table} bal
   
   LEFT JOIN {Invoice header table} i 
      ON bal.TXTINVOICE = i.TXTINVOICE
   
   LEFT JOIN (
      -- Fund-level aggregation. Included here as a sub-query instead of its own CTE so that this whole CTE can be re-used elsewhere w/o having to copy/paste multiple, scattered tables
      SELECT 
         TXTINVOICE, 
         FUND, 
         SUM(CURAMOUNT) AS PERFUNDTOTAL
      FROM {Invoice Line details table}
      GROUP BY 
         TXTINVOICE, 
         FUND
   ) fndln
      ON bal.TXTINVOICE = fndln.TXTINVOICE
   
   LEFT JOIN {Invoice Line details table} fpln -- This adds the FOAPAL level details for every Inv  
      ON fndln.TXTINVOICE = fpln.TXTINVOICE
      AND fndln.FUND = fpln.FUND
   
   WHERE
      bal.BLNPOSTED = -1 -- Only posted balances
      AND bal.OUTSTANDING > 0 -- Only invoices w/ outstanding amounts
),

-- 2) Get Transactions and their details to match against Open Invoices

--- 2a) Get Transactions and details
    -- Previous reports used SYNTRANDETAIL_ALL but that data took 2 days to hit FAST. Gavin found and suggested using this table instead bc it has near-real-time data
Transactions AS (
   -- Columns are aliased here so I can leave the rest of everything AS IS and NOT have to change ALL the references downstream to 'FGBTRNH_{column name}_CODE'
   SELECT
      FGBTRNH_SURROGATE_ID AS TranID,
      FGBTRNH_COAS_CODE AS CHART,
      FGBTRNH_ACCI_CODE AS ACCI,
      FGBTRNH_FUND_CODE AS FUND,
      FGBTRNH_ORGN_CODE AS ORGN,
      FGBTRNH_ACCT_CODE AS ACCT,
      FGBTRNH_PROG_CODE AS PROG,
      FGBTRNH_ACTV_CODE AS ACTV,
      FGBTRNH_LOCN_CODE AS LOCN,
      FGBTRNH_TRANS_AMT AS AMOUNT,
      FGBTRNH_TRANS_DESC AS DESCRIPTION,
      FGBTRNH_TRANS_DATE AS TRANDATE,
      FGBTRNH_DR_CR_IND AS DCIND,
      FGBTRNH_DOC_CODE AS DOCUMENT,
      FGBTRNH_DOC_REF_NUM AS DOCREFNUM,
      FGBTRNH_SEQ_NUM AS SEQNUMBER,
      FGBTRNH_RUCL_CODE AS RUCL_CODE,
      FGBTRNH_USER_ID AS USER_ID  

FROM {Transaction Table} 
),

--- 2b) Pre-filter Transactions
    -- As of 1/26, there are over 27 million transactions
    -- the 'inv comparison' calculations in the SignalTransactions cte below are VERY computation 'heavy' and should NOT be run for THAT many records
    -- ie, we need to get as small a dataset as possible 
    -- BUT need to ALSO not exclude TOO much upfront (previous query included only 'closing credits' (Field code = 'GCR') but SOME misplaced pmts were coded 'YTD' and were being left out) 
FilteredTransactions AS (
   SELECT 
      bt.*,
      UPPER(bt.DESCRIPTION) AS upperDescription -- 'normalizes' the text so we can better search it later for Inv numbers
      
      -- The below FrankenID can PROBABLY go away bc there's a 'Surrogate ID' in the NEW table. Keeping until sure it works the same
      --COALESCE(bt.description, '') || '|' || ABS(bt.amount) || '|' || bt.trandate || '|' || COALESCE(bt.document, '') || '|' || COALESCE(bt.docrefnum, '') || '|' || bt.seqnumber AS tranID -- ID used to flag transactions w/ an 'FI token' and count Debits later
      
   FROM Transactions bt
   
   WHERE -- filtering rules outlined in the intro section
      bt.RUCL_CODE IN ('JE16','RCP') 
      AND bt.ACCT NOT IN ('{Excluded_AR_Accounts}') 
      AND bt.TRANDATE >= ( -- BIGGEST 'slicer' by far (Takes row count from 27mil to 2mil) 
         SELECT MIN(DATINVOICEDATE) - 14 -- occurred 2 wks prior or after OLDEST open invdate
         FROM OutstandingInvoices
      )
),

-- The above filters take the number of records down to around 250k 

--- 2c) Pre-match the filtered transactions
    -- Checks each transaction for ANY matching signal (Amt, Date, FOAPAL codes, etc) that matches ANY signal from ANY open inv. Excludes rows with less than 2
    -- the 'Signal checks' below are run HERE instead of with the filters in the previous CTE in an effort to run 'heavier' computations for only 250k rows instead of 27 million
SignalTransactions AS (
   SELECT
      ft.*
   FROM FilteredTransactions ft
   WHERE
      EXISTS ( -- if tran amt matches any of 4 possible Inv amts
         SELECT 1
         FROM OutstandingInvoices i
         WHERE
            ABS(ft.AMOUNT) IN (
               i.INVAMOUNT,
               i.OUTSTANDING,
               i.PERFUNDTOTAL,
               i.FOAPALlineTotal)
            AND ft.TRANDATE >= i.DATINVOICEDATE - 14)
      OR ( -- if tran description contains an 'FI token'. The following REGEX expressions are explained in the next CTE
         REGEXP_LIKE(ft.upperDescription, '(^|' || CHR(91) || '^A-Z0-9' || CHR(93) || ')FI' || CHR(91) || 'A-Z0-9' || CHR(93) || '{5,7}' || '(' || CHR(91) || '^A-Z0-9' || CHR(93) || '|$)', 'i') 
         AND NVL(REGEXP_COUNT(REGEXP_SUBSTR(ft.upperDescription, '(^|' || CHR(91) || '^A-Z0-9' || CHR(93) || ')FI' || CHR(91) || 'A-Z0-9' || CHR(93) || '{5,7}' || '(' || CHR(91) || '^A-Z0-9' || CHR(93) || '|$)', 1, 1), '\d'), 0) >= 5)
      OR EXISTS (
         SELECT 1
         FROM OutstandingInvoices i
         WHERE
            (CASE WHEN ft.FUND = i.FUND THEN 1 ELSE 0 END
            + CASE WHEN ft.ACCT = i.ACCT THEN 1 ELSE 0 END
            + CASE WHEN ft.ORGN = i.ORGN THEN 1 ELSE 0 END
            + CASE WHEN ft.PROG = i.PROG THEN 1 ELSE 0 END
            + CASE WHEN ft.ACCI = i.ACCI THEN 1 ELSE 0 END) >= 2 -- keep rows that have at least TWO matching Signals (as explained in Intro notes)
            AND ft.TRANDATE >= i.DATINVOICEDATE - 14 )
),

--- 2d) Flag transactions that have an 'FI' inv # in the description or anything CLOSE to one (in case of typos) 
    -- The REGEX below (and in the above CTE) identify rows with an 'FI' in the description followed by 5-7 chars where 5 of those are DIGITS. This catches:
        -- omitted digits: 'FI00123'
        -- added digits: 'FI0001234'
        -- if a letter slips in there: 'FI00o123'
        -- DIGIT check keeps from flagging 'Fish and Chips' as having an Inv #
   -- Running REGEX is 'heavy' and we check for an 'FI Token' SEVERAL times later on 
   -- Storing a list of them HERE means we only need to run scans ONCE and then simply check if a transaction is flagged in this list as having an FI Token 
   -- NOTE: we HAVE to use 'CHR()' instead of square brackets for the Regex functions bc although they're perfectly LEGIT, FAST's parser reads them wrong and prompts for user input and the query doesn't run. Sheesh
FI_transactions AS (
   SELECT
      st.TranID, 
      st.upperDescription
   FROM SignalTransactions st
   WHERE
      REGEXP_LIKE(st.upperDescription, '(^|' || CHR(91) || '^A-Z0-9' || CHR(93) || ')FI' || CHR(91) || 'A-Z0-9' || CHR(93) || '{5,7}' || '(' || CHR(91) || '^A-Z0-9' || CHR(93) || '|$)', 'i') -- checks for existence of an 'FI' followed by 5-7 char
      AND NVL(REGEXP_COUNT(REGEXP_SUBSTR(st.upperDescription, '(^|' || CHR(91) || '^A-Z0-9' || CHR(93) || ')FI' || CHR(91) || 'A-Z0-9' || CHR(93) || '{5,7}' || '(' || CHR(91) || '^A-Z0-9' || CHR(93) || '|$)', 1, 1), '\d'), 0) >= 5 -- checks if at least 5 of those char are DIGITS
),

-- 3) Compare and Combine Transactions and Invoices 
    -- Takes INVOICE details and searches the TRANSACTIONS for any matching signals, then calculates a 'Matching Score' for each
    
    -- IMPORTANT: for THIS part of the process, the INVOICE table is the 'driver' NOT the transactions
         -- with over 250k tran rows, if EACH one has signals that match only ONE inv, that's STILL 250k calculations. Even if the match is 'weak'. And it's MORE than likely that each tran has signals matching MANY invoices. That's IMPOSSIBLY huge to calculate
         -- Conversely, for the smaller set of Open invoices (~100), we can take each of THOSE and find the handful of transactions w/ matching signals and it's a MUCH lighter 'computational load'
         -- Even though the INNER JOIN would result in the same ROWS, one report runs while the other would time out or crash
    -- Driving from the Invoice side also: 
       -- makes it easier to search the tran description for an Inv# instead of having to find, extract, and clean an Inv# from a desc and compare it to open invoices
       -- filters rows FURTHER bc invoices are only compared to the subset of transactions that occurred since their inv date
    
    -- A matching line's 'Total Score' is calculated based BOTH on number of matching Signals AND their 'weight'. 
    -- ie- a transaction containing an Inv# is a MUCH stronger signal of a possible match than one that only matches on a fairly common Acct code
    -- Scoring method can be adjusted by WHICH signals get a score and how HIGH that score should be   
ScoredTransactions AS (
   SELECT 
      -- Transaction detail columns
      t.tranID,
      t.ACCI AS TranIndex,
      t.FUND AS TranFund,	
      t.ORGN AS TranOrg,	
      t.ACCT AS TranAcct,
      t.PROG AS TranProg,	
      t.ACTV AS TranActv,	
      t.LOCN AS TranLocn,	
      t.AMOUNT,
      t.DCIND,
      t.DESCRIPTION,
      t.TRANDATE,
      t.DOCUMENT,
      t.DOCREFNUM,
      t.SEQNUMBER,
      t.RUCL_CODE,
      t.USER_ID,
      
      NULL as Invoice_Details, -- added as 'visual spacer'. Can delete later
      
      -- Invoice detail columns
      i.*,
      
      NULL as Match_Details, -- added as 'visual spacer'. Can delete later

      -- columns to explain WHY a tran is included/ which signals are a match
      -- These 4 columns exactly mirror logic in the scoring equation below. Used here for MESSAGES instead of a score
      CASE
         WHEN INSTR(fi.upperDescription, i.txtinvoice) > 0 THEN 'Exact' -- checks if a given Invoice's FI# is found in a transaction's desc 
         WHEN fi.tranID IS NOT NULL THEN 'Possible Inv # Found' -- if not the EXACT inv# but something LIKE an inv#, it gets flagged for review
         ELSE 'No Inv# found'
      END AS InvNumMatch,

      RTRIM( -- specifies exactly WHICH codes match
         CASE WHEN t.FUND = i.FUND THEN 'FUND, ' END ||
         CASE WHEN t.ORGN = i.ORGN THEN 'ORGN, ' END ||
         CASE WHEN t.ACCT = i.ACCT THEN 'ACCT, ' END ||
         CASE WHEN t.PROG = i.PROG THEN 'PROG, ' END ||
         CASE WHEN t.ACTV = i.ACTV THEN 'ACTV, ' END ||
         CASE WHEN t.LOCN = i.LOCN THEN 'LOCN, ' END ||
         CASE WHEN t.ACCI = i.ACCI THEN 'ACCI, ' END
         , ', '
      ) AS FOAPALmatches,
      
      CASE -- specifies WHICH amt matches
         WHEN ABS(t.AMOUNT) = i.INVAMOUNT THEN 'Inv Total'
         WHEN ABS(t.AMOUNT) = i.PERFUNDTOTAL THEN 'per Fund Total'
         WHEN ABS(t.AMOUNT) = i.FOAPALlineTotal THEN 'FOAPAL line total'
         WHEN ABS(t.AMOUNT) = i.OUTSTANDING THEN 'Outstanding Balance'
         ELSE NULL 
      END AS AmtMatch,
      
      CASE -- notes if the tran occurred before or AFTER the inv date
         WHEN t.TRANDATE >= i.DATINVOICEDATE THEN 'Pmt after Inv Date' 
         ELSE 'Pmt predates Inv' 
      END AS DateMatch,

      /* Total Matching Score Equation */
      -- These scoring 'blocks' exactly mirror the logic above. Used here to return an actual NUMBER
      (
         -- Inv # matching
         CASE
            WHEN INSTR(fi.upperDescription, i.txtinvoice) > 0 THEN 5 -- if EXACT Inv# is found 
            WHEN fi.tranID IS NOT NULL THEN 1 -- if AN inv# (or something LIKE one) is found
            ELSE 0
         END
         +
         -- FOAPAL codes matching 
         ( -- 1 point for each Code that matches
         CASE WHEN t.FUND = i.FUND THEN 1 ELSE 0 END
         + CASE WHEN t.ORGN = i.ORGN THEN 1 ELSE 0 END
         + CASE WHEN t.ACCT = i.ACCT THEN 1 ELSE 0 END
         + CASE WHEN t.PROG = i.PROG THEN 1 ELSE 0 END
         + CASE WHEN t.ACTV = i.ACTV THEN 1 ELSE 0 END
         + CASE WHEN t.LOCN = i.LOCN THEN 1 ELSE 0 END
         + CASE WHEN t.ACCI = i.ACCI THEN 1 ELSE 0 END
         )

         -- Amounts matching
         + 
         CASE WHEN 
                  ABS(t.AMOUNT) = i.FOAPALlineTotal
                  OR ABS(t.AMOUNT) = i.PERFUNDTOTAL
                  OR ABS(t.AMOUNT) = i.INVAMOUNT
                  OR ABS(t.AMOUNT) = i.OUTSTANDING
               THEN 2 ELSE 0 -- if the tran amount matches an amt from an inv, that's a STRONGER signal than if a tran only matches on a couple of accounting codes. At least to me. Can adjust as desired. 
         END

         -- TranDate >= Inv Date
         + CASE WHEN t.TRANDATE >= i.DATINVOICEDATE THEN 1 ELSE 0 END -- extra point for if tran occurs AFTER an inv date. Pmts occuring BEFORE an inv date are EXTREMELY rare and therefore PROBABLY not a strong match
      ) AS InvLineScore

   FROM OutstandingInvoices i
   JOIN SignalTransactions t 
      ON 
         t.TRANDATE >= i.DATINVOICEDATE - 14 -- only joins an inv on transactions that occur NEAR or after its inv date 
         AND ( -- we use OR logic to JOIN on ANY match. This results in a LOT of 'weak' matches but we eliminate THOSE using the 'confidence threshold' in the following CTE
            t.FUND = i.FUND 
            OR t.ORGN = i.ORGN 
            OR t.ACCT = i.ACCT 
            OR t.PROG = i.PROG 
            OR t.ACTV = i.ACTV 
            OR t.LOCN = i.LOCN 
            OR t.ACCI = i.ACCI 
            OR ABS(t.AMOUNT) = i.FOAPALlineTotal
            OR ABS(t.AMOUNT) = i.PERFUNDTOTAL
            OR ABS(t.AMOUNT) = i.INVAMOUNT
            OR ABS(t.AMOUNT) = i.OUTSTANDING
         )
   LEFT JOIN FI_transactions fi
      ON t.tranID = fi.tranID
),

-- 4) Select ONLY the Transactions w/ a HIGH confidence score and display results in an organized and understandable way

/* ==========       Buckle Up...     ==============

-- Believe it or not, this last part was the hardest by a MILE. It's pretty complicated (to me anyway) so we'll tackle it in steps:
   - Select JUST the results we want
   - Organize results in a useful way
   - Display results so humans can actually read them

-- SELECT:
   - As of 1/26, initial 'threshold' for matches to include is >= 7 (suggested by Gavin. I had NO clue what would ACTUALLY be helpful)
   - PRIMARILY interested in just Credits
   - Easy-peasy-ish

-- ORGANIZE:
   - As previously mentioned, the goal is:
      1) Most recent transactions first
      2) if MORE than one inv matches, show the BEST match first

   - The following ORDER BY logic gets us CLOSE:
      - TranDate DESC,
      - TranID,
      - Inv#,
      - InvLineScore DESC

   - one BIG issue: this only sorts Inv LINES within a transaction by inv NUMBER, not by 'Best matching' Inv first
   - THIS is where it starts to get tricky
   - Because matching and scoring happens at the inv LINE level not the INVOICE level, sorting by Best LINE score 'scatters' anything from the same inv# with different scores
      TranA | Inv1 | Score:11
      TranA | Inv2 | Score:10
      TranA | Inv3 | Score:9
      TranA | Inv2 | Score:8
      TranA | Inv1 | Score:7

   - If we want lines from the same Inv# to be together (which we do. It looks WAY better), we need to 'lock' them as GROUPS and then sort the GROUPS by Best Match

   - No real way in SQL to keep things together as a UNIT. But we CAN create 'pseudo groups' by sorting all items we want to group by a shared value
   - Ex: the above ORDER BY clause divides all transactions into 'DATE groups', then splits each Date group into 'TRANSACTION Groups', etc.

   - In other words, if we want to GROUP lines by inv# and SORT the invoice GROUP by best match, we need an 'INVOICE score', not just Inv# or LINE Score
   - To solve this, we use a MAX() function to get all LINES from an Inv#, take the highest LINE score from that group, and set THAT as the INVOICE score

-- DISPLAY / DECLUTTER:
   - Recall that the INNER JOIN creates duplicate transaction rows for EVERY matching Inv Line
   - This becomes TOO much to visually parse (easily)
   - Luckily, we can use CASE statements to conditionally format the data to create 'row headers' and hide unnecessary, duplicate info
   - BUT, for the CASE logic to work, the Transaction and Invoice 'groups' have to have row numbers
   - In order to THAT, we need to use 3 separate 'SELECT layers' bc of how SQL operates
   - Namely, SQL doesn't let you compute a value (ex: a column alias or 'window function' like Row_Number) and then use the results elsewhere in that SAME 'SELECT layer' 
      - in other words, a value has to be computed in ONE 'layer' and THEN it can be used in another
   - Which means the CASE blocks that use the 'TranGroupLine' and 'InvGroupLine' variables MUST be in a seperate layer than where those columns are defined 
   - On top of that, bc THOSE columns use 'InvGroupScore' in their functions, THEY need to be in a separate layer from where THAT is computed
   - ie:
      SELECT c
      FROM (
         SELECT function(b) AS c
         FROM (
            SELECT function(a) AS b
            FROM table ))) ---> 3 layers

-- SUMMARY:
   - Because payments can go wandering for any NUMBER of reasons, we need to match on more than ONE 'signal'
   - Because we JOIN on every match, we end up w/ MANY rows for ONE transaction w/ details duplicated across each row
   - Because we need to be able to UNDERSTAND the results, we need to hide unnecessary info
   - Because we use conditional CASE statements to hide duplicated rows, we need groups to have row numbers 
   - Because we use several different 'window functions' to generate row numbers but can't USE them in the same layer, we need separate layers for any column that uses a computed value
   - Because our SELECT uses a computed value and THAT computed value uses ANOTHER computed value, we need a minimum of THREE select layers
   - FINALLY, because this is all SO UNBELIEVABLY COMPLEX, I have now spent WEEKS on ONE friggin' query and have consequently gone MORE than a little insane

   Many Bothans died to bring us this information. But the {reporting} needs of the many outweigh the {mental stability} needs of the one
========================== */

--- 4a) FIRST layer: Select JUST the matches above a certain 'confidence threshold' 
    -- This CTE also creates the 'group score' used in the next layer   
MatchedResults AS (
   SELECT 
         MAX(s.InvLineScore) OVER (
            PARTITION BY -- for EACH unique TranID, group EACH matching Inv LINE by unique Inv# and give it a GROUP score equal to its highest LINE score  
               s.tranID, 
               s.TXTINVOICE
         ) AS InvGroupScore,
         s.* 
      FROM ScoredTransactions s 
      WHERE 
         s.DCIND = 'C' -- Limits rows to JUST Credits
         AND s.InvLineScore >= 7 -- set confidence threshold HERE
),

--- 4b) SECOND layer: GROUP and SORT results 
    -- TranGroupLine, InvMatch, and InvGroupLine computed HERE so as to be useable in the FINAL layer
    -- Debit table is ALSO 'heavy' so we waited to until NOW to JOIN it AFTER we'd filtered to the final results to reduce computation
    -- FINAL sort logic found HERE
SortedMatches AS (  
   SELECT 
      -- Order By clauses INSIDE Window Functions will OVERRIDE any sorting elsewhere 
      -- ie: if we want results to be sorted in the order shown in the SELECT statement's ORDER BY clause, a FUNCTION's clause must use the EXACT same logic
      
      -- Group rows by TranID and numbers each row in that group. Used to create row headers
      ROW_NUMBER() OVER (   
         PARTITION BY m.tranID 
         ORDER BY -- see OVERRIDE note above   
            m.InvGroupScore DESC,
            m.txtinvoice, 
            m.InvLineScore DESC,
            m.FoapalLineID
      ) AS TranGroupLine, 
      
      -- give each possible match a number. Enhances readability
      DENSE_RANK () OVER (
         PARTITION BY 
               m.tranID
            ORDER BY -- see OVERRIDE note above
               m.InvGroupScore DESC,
               m.TXTINVOICE
      ) AS InvMatch,

       -- group any/all matching foapal lines from the same Inv# together and indicates how MANY lines of an Inv group match the transaction
      ROW_NUMBER() OVER (
            PARTITION BY 
               m.tranID, 
               m.TXTINVOICE 
            ORDER BY -- see OVERRIDE note above
               m.InvLineScore DESC,
               m.FoapalLineID 
      ) AS InvGroupLine, 
      m.*,
      d.DebitMatches, 
      d.DebitDetails 
   FROM MatchedResults m
   
   -- Some transactions have already been 'taken care of'. This table checks if a tran has a matching 'correcting' Debit entry and returns anything it finds  
   LEFT JOIN (
      SELECT
         s.TXTINVOICE,
         s.FoapalLineID,
         ABS(s.AMOUNT) AS AmtAbs,
         COUNT(*) AS DebitMatches,
         CASE 
            WHEN COUNT(*) = 1 
               THEN MAX(TO_CHAR(s.TRANDATE, 'YYYY-MM-DD') || ' - ' || s.DESCRIPTION) 
            WHEN COUNT(*) > 1
               THEN 'Various'
            ELSE NULL
         END AS DebitDetails
      FROM ScoredTransactions s
      WHERE
         s.DCIND = 'D'
         AND s.InvLineScore >= 7 -- needs to match the threshold set above
      GROUP BY
         s.TXTINVOICE,
         s.FOAPALlineID,
         ABS(s.AMOUNT)
   ) d
      ON d.TXTINVOICE = m.TXTINVOICE
      AND d.FoapalLineID = m.FoapalLineID
      AND d.AmtAbs = ABS(m.AMOUNT)
   ORDER BY 
      m.TRANDATE DESC, -- MOST RECENT transaction first 
      m.tranID, -- keep all of a transaction's rows together 
      m.InvGroupScore DESC, -- within a tran group, best Inv Score 1st  
      m.txtinvoice, -- keep all an invoice's lines together
      m.InvLineScore DESC, -- winthin an inv group, highest LINE score 1st
      m.FoapalLineID -- sort by LineID in case of a tie
)

--- 4c) FINAL layer: Display results 
    -- visual layer ONLY
SELECT 
   -- Transaction columns
   -- CASE statements used so that details are displayed only on the FIRST row of every transaction
   CASE WHEN sm.TranGroupLine = 1 THEN sm.TRANID ELSE NULL END AS TranID,
   CASE WHEN sm.TranGroupLine = 1 THEN sm.TRANINDEX ELSE NULL END AS IndexCode,   
   CASE WHEN sm.TranGroupLine = 1 THEN sm.TRANFUND ELSE NULL END AS FUND, 
   CASE WHEN sm.TranGroupLine = 1 THEN sm.TRANORG ELSE NULL END AS ORGN, 
   CASE WHEN sm.TranGroupLine = 1 THEN sm.TRANACCT ELSE NULL END AS ACCT, 
   CASE WHEN sm.TranGroupLine = 1 THEN sm.TRANPROG ELSE NULL END AS PROG, 
   CASE WHEN sm.TranGroupLine = 1 THEN sm.TRANACTV ELSE NULL END AS ACTV, 
   CASE WHEN sm.TranGroupLine = 1 THEN sm.TRANLOCN ELSE NULL END AS LOCN, 
   CASE WHEN sm.TranGroupLine = 1 THEN sm.AMOUNT ELSE NULL END AS AMOUNT, 
   CASE WHEN sm.TranGroupLine = 1 THEN sm.DESCRIPTION ELSE NULL END AS DESCRIPTION, 
   CASE WHEN sm.TranGroupLine = 1 THEN sm.TRANDATE ELSE NULL END AS TRANDATE, 
   CASE WHEN sm.TranGroupLine = 1 THEN sm.DOCUMENT ELSE NULL END AS DOCUMENT, 
   CASE WHEN sm.TranGroupLine = 1 THEN sm.DOCREFNUM ELSE NULL END AS BannerRcpt, 
   CASE WHEN sm.TranGroupLine = 1 THEN sm.SEQNUMBER ELSE NULL END AS DocLineNum, 
   CASE WHEN sm.TranGroupLine = 1 THEN sm.RUCL_CODE ELSE NULL END AS RUCL, 
   CASE WHEN sm.TranGroupLine = 1 THEN sm.USER_ID ELSE NULL END AS EnteredBy, 
   
   -- Inv columns
   sm.Invoice_Details, -- visual spacer. maybe delete later? 
   -- same logic, InvGroupLine is used to show inv details on only the FIRST row of Inv lines
   CASE WHEN sm.InvGroupLine = 1 THEN sm.InvMatch ELSE NULL END AS InvMatch, 
   CASE WHEN sm.InvGroupLine = 1 THEN sm.TXTINVOICE ELSE NULL END AS INVOICE, 
   CASE WHEN sm.InvGroupLine = 1 THEN sm.TXTDEPT ELSE NULL END AS Dept, 
   CASE WHEN sm.InvGroupLine = 1 THEN sm.TXTCREATED ELSE NULL END AS InvCreator, 
   CASE WHEN sm.InvGroupLine = 1 THEN sm.CTRCUSTOMER ELSE NULL END AS CustNum, 
   CASE WHEN sm.InvGroupLine = 1 THEN sm.TXTCUSTOMERNAME ELSE NULL END AS Customer, 
   CASE WHEN sm.InvGroupLine = 1 THEN sm.DATINVOICEDATE ELSE NULL END AS InvDate,
   sm.InvGroupLine,
   sm.InvLineScore, 
   sm.ACCI AS InvIndex, 
   sm.FUND AS InvFund, 
   sm.ORGN AS InvOrg, 
   sm.ACCT AS InvAcct, 
   sm.PROG AS InvProg, 
   sm.ACTV AS InvActv, 
   sm.LOCN AS InvLocn, 
   CASE -- used to hide FOAPAL amt when tran amt matches at a HIGHER level
      WHEN 
         sm.AMOUNT = sm.FOAPALlineTotal 
         AND sm.FOAPALlineTotal <> sm.PERFUNDTOTAL THEN sm.FOAPALlineTotal 
      ELSE NULL 
   END AS FOAPALlineTotal, 
   CASE -- used to show/hide FUND amt
      WHEN 
         (sm.AMOUNT = sm.FOAPALlineTotal -- show if different from FOAPAL total 
            AND sm.FOAPALlineTotal <> sm.PERFUNDTOTAL) 
         OR (sm.AMOUNT = sm.PERFUNDTOTAL -- show if different that INV total
            AND sm.PERFUNDTOTAL <> sm.INVAMOUNT) 
      THEN sm.PERFUNDTOTAL 
      ELSE NULL 
   END AS PERFUNDTOTAL, 
   sm.INVAMOUNT, 
   sm.PAYMENTS, 
   sm.ADJUSTMENTS, 
   CASE WHEN sm.PAYMENTS > 0 THEN sm.OUTSTANDING ELSE NULL END AS OUTSTANDING, 
   
   -- Match Columns
   sm.Match_Details, -- visual spacer. maybe delete later? 
   sm.InvNumMatch, 
   sm.FOAPALmatches, 
   sm.AmtMatch, 
   sm.DateMatch, 
   sm.DebitMatches,
   sm.DebitDetails 
  
FROM SortedMatches sm
