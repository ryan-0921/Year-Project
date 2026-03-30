## Error Handling and Continuation Behavior

This document explains in detail how the script continues processing **subsections** and **sections** even when some of them fail.

---

## 1. High-level Behavior

- **Within a section (especially Section 1)**:  
  If a subsection fails, the script **logs the failure but continues** processing all remaining subsections.

- **Between top-level sections**:  
  If one requested section fails (for example, section `1`), the script **still processes the other requested sections** (for example, `3`, `5`).

- **At the very end**:  
  The script:
  - Summarizes which sections/subsections failed.
  - Sets a **non-zero exit code** (`exit 1`) only if at least one section has failed, but only **after all processing is complete**.

This behavior is implemented at two levels:

- **Subsection level** inside Section 1: `process_section_1_detailed`.
- **Section level** in `main` via the `process_section` function and a `failed_sections` array.

---

## 2. Subsection-Level Continuation (Section 1)

Section 1 uses a special engine: `process_section_1_detailed`. This function processes **every** subsection (`1.1.1.1` through `1.7.10`), regardless of whether earlier subsections fail.

### 2.1 Overall Success Flag

At the top of `process_section_1_detailed`:

- An `overall_success` flag is initialized to `true`.
- An array `subsection_results` collects per-subsection results.

When a subsection fails (either because hardening could not be applied or verification failed), the function:

- Sets `overall_success=false`.
- Still **returns to the caller of the subsection helper** and proceeds to the next subsection.

At the end of `process_section_1_detailed`:

- If `overall_success` is still `true`, the function returns `0` (success).
- If any subsection set `overall_success=false`, the function returns `1` (failure for Section 1 as a whole).

This design ensures:

- **All** subsections are attempted and logged.
- Section 1’s final status reflects the aggregate of all subsections instead of failing on the first error.

### 2.2 Subsection Helper: `process_subsection`

Each subsection is processed by a nested helper function `process_subsection "$sub_section"`.

For each `sub_section` (e.g. `1.3.1.3`), the helper:

1. **Checks compliance** using `check_compliance "$sub_section"`.
   - If already compliant:
     - Marks the subsection as **SKIPPED** in the CSV report.
     - Logs a success message.
     - Returns `0` (success) without applying any changes.

2. **Applies hardening** using `apply_hardening "$sub_section"` if not compliant.
   - If `apply_hardening` fails:
     - Logs an error (`FAILED`).
     - Writes a `FAILED` entry for that subsection to the report.
     - Sets `overall_success=false`.
     - Returns `1`, but **does not stop the overall loop** in `process_section_1_detailed`.

3. **Verifies hardening** where appropriate:
   - It may skip verification for:
     - Manual subsections (e.g. `1.1.1.10`, `1.2.x.x`, `1.4.1`), which require manual action.
     - Mount-option subsections where the related mount point does **not** exist in `/etc/fstab` (indicating manual partitioning).
   - If verification runs and fails:
     - Logs an error (`VERIFY_FAILED`).
     - Writes a `VERIFY_FAILED` entry to the report.
     - Sets `overall_success=false`.
     - Returns `1`, but the next subsections are still processed.

4. **Records results**:
   - For every subsection, regardless of outcome, an entry is added to:
     - The `subsection_results` array (for the log summary).
     - The CSV report (with status `SKIPPED`, `FIXED`, `FAILED`, or `VERIFY_FAILED`).

Because `process_section_1_detailed` calls `process_subsection` **sequentially** for every defined subsection and never exits early on failure, all subsections get a chance to run and report their status.

---

## 3. Section-Level Continuation (`main` and `process_section`)

At the **section** level (e.g. sections `1`, `3`, `5`), the continuation behavior is managed by `main`.

### 3.1 Looping Through Requested Sections

`main` builds an array `SECTIONS` (e.g. `("1" "3" "5")`) from the command line arguments. Then it does:

- Initializes `failed_sections=()`.
- Loops over each requested `section`.
- Calls `process_section "$section"` for each one.

### 3.2 Handling Section Failures

For each section:

- If `process_section "$section"` returns **0**:
  - The section is considered successful.
- If `process_section "$section"` returns **non-zero**:
  - That `section` is appended to the `failed_sections` array.
  - A warning is logged indicating that the section failed but the script will **continue with remaining sections**.

The loop **never exits early** due to a failure in one section; it always iterates through all requested sections.

### 3.3 Final Exit Code and Summary

After all sections have been processed:

- The script:
  - Compresses the backup directory (if not in dry-run mode).
  - Calls `generate_summary` to log high-level counts (Fixed, Skipped, Failed, Verify failed, etc.).
- Then it checks `failed_sections`:
  - If `failed_sections` is **non-empty**:
    - Logs a warning listing the failed sections.
    - Exits with `exit 1`.
  - If `failed_sections` is empty:
    - Logs either:
      - A dry-run success message, or
      - A full success message for all sections.
    - Exits with `exit 0`.

This design ensures:

- You always see **results for every requested section**, even when some fail.
- External tools (CI, automation, etc.) can still rely on the final exit code to detect whether overall hardening was fully successful.

---

## 4. Why This Design Is Useful

- **Resilience**: A single misconfiguration (e.g. one AppArmor setting) does not block all other hardening tasks from applying.
- **Visibility**: You get a full per-subsection and per-section picture:
  - Which items are already compliant.
  - Which were fixed.
  - Which failed or failed verification.
- **Automation-friendly**: The script’s **final exit code** correctly signals whether any section failed, while still ensuring that all viable changes were attempted in a single run.

