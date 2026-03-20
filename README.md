# Transactions that might be Payments for AR invoices

## Description
Payments intended for AR invoices sometimes go 'wandering' — either due to missing remittance info or plain human error. This project was built to help proactively track those down by matching transactions and their details against a list of open invoices. 

A previous version of this report looked for **exact** matches where Transaction Amount = Invoice Total. 
### Problem
While somewhat successful, usefulness was limited because:
- matching only on amount returns too many false positives
- including a second transaction detail or 'signal' (accounting codes, dates, invoice #s, etc.) for exact matching isn’t an option, because **any part** of a transaction can be wrong and it's impossible to know WHICH details are correct and usable. (e.g., filtering by date would exclude valid matches that were simply misdated)
- which signals are accurate vs incorrect can (and DO) vary from one transaction to the next (e.g., one may have correct dates but no invoice number, while another has an inv # but incorrect acct codes)
- this resulted in a list of hardcoded rules for each edge case, that still missed catching all valid matches and required constant updates as new exceptions were discovered

### Solution
Instead of relying on EXACT matches across one or TWO signals, THIS version uses a **scoring model** to evaluate transactions based on POSSIBLE matches across ALL signals. Each transaction is then assigned a total score on a SPECTRUM of how likely it is to be a match, and results can then be filtered using a chosen 'confidence threshold'.

This approach is more flexible, scalable, and consequently more EFFECTIVE

## Key Highlights:
- Because matching criteria is derived from only those invoices that are currently open, the system is now **dynamic** and no longer relies on maintaining static and brittle rules to catch everything
- Including more signals to match against casts a much wider net so we miss less
- Matching on more signals returns fewer false positives and allows for higher confidence in possible matches
- Using a confidence threshold to include/exclude results allows for a RANGE of matches instead of overly strict yes/no rules.
- Because some Invoices are split between multiple account codes, this updated version now uses Invoice LINE-LEVEL details to match transactions against instead of the Invoice TOTAL-Level
- Previously, data was pulled from tables that were almost 2 days old. This version pulls from a new source with near real-time data

## Features
- Multi-signal matching, including:
  - Transaction AMOUNT
  - (NEW) ADDITIONAL amounts: invoice LINE total, **per-FUND**-code total, **Outstanding** total (for partial payments)
  - (NEW) Detection of **invoice numbers** (or near matches) in transaction **Descriptions**
  - (NEW) Matching across **'FOAPAL' accounting codes** (Fund, Org, Acct, Prog, Actv, Locn, Index)
  - (NEW) **Transaction date proximity** to invoice date (also configurable)
- Configurable **confidence threshold** to control match strength
- Advanced grouping and sorting to visually present results in a **human-readable format** 
- Inline explanations showing **why** a transaction was flagged as a potential match

## Tech & Techniques
- **SQL (Oracle)**  
  - **Common Table Expressions (CTEs)** for modular, stepwise data transformation  
  - **Window Functions** (`ROW_NUMBER`, `DENSE_RANK`, `MAX OVER`) for grouping, ranking, and sorting 
  - **Advanced visual presentation** using conditional logic (`CASE`) to improve human readability
  - **Multi-level aggregation** (Invoice, Fund, FOAPAL line)  
  - **Scoring / ranking model** implemented directly in SQL (no external tooling)
  - **Performance optimization** via staged filtering (reducing ~27M rows → targeted subset before heavy computation)  
- **Regular Expressions (REGEXP)** for pattern detection and fuzzy invoice number matching   

- ERP financial system (Millennium FAST)
- University system of record (Ellucian Banner)

## Additional Context on Design & Documentation
- This report was developed for an internal finance team with strong reporting knowledge but varying levels of SQL experience. As a result, the original file includes EXTENSIVE inline documentation to make the logic understandable and maintainable for team members who are less familiar with advanced SQL patterns.
- This portfolio version has been anonymized for clarity, but preserves the core architecture of the original solution
- Inline comments have been largely retained as an example of writing technical documentation for a mixed-technical audience.

## Visuals
(coming soon)


## Contributing

This repo is currently for portfolio purposes; external contributions are not being accepted.

## Authors and Acknowledgment

Developed and designed by m@t with business logic requirements provided by Gavin, Suzanne, and Jenny.

## License

This repository is for portfolio and showcase purposes. All code and examples are anonymized to protect sensitive data.

## Project Status

✅ Completed and in production. Used daily by internal stakeholders with positive feedback on usability and accuracy.
