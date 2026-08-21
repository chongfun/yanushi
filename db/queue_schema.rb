# This file is auto-generated from the current state of the database. Instead
# of editing this file, please use the migrations feature of Active Record to
# incrementally modify your database, and then regenerate this schema definition.
#
# This file is the source Rails uses to define your schema when running `bin/rails
# db:schema:load`. When creating a new database, `bin/rails db:schema:load` tends to
# be faster and is potentially less error prone than running all of your
# migrations from scratch. Old migrations may fail to apply correctly if those
# migrations use external dependencies or application code.
#
# It's strongly recommended that you check this file into your version control system.

ActiveRecord::Schema[8.1].define(version: 2026_08_16_000010) do
  # These are extensions that must be enabled in order to support this database
  enable_extension "pg_catalog.plpgsql"

  create_table "accounts", force: :cascade do |t|
    t.string "account_type", null: false
    t.boolean "active", default: true, null: false
    t.datetime "created_at", null: false
    t.string "key", null: false
    t.string "name", null: false
    t.datetime "updated_at", null: false
    t.bigint "user_id", null: false
    t.index ["user_id", "key"], name: "index_accounts_on_user_id_and_key", unique: true
    t.index ["user_id"], name: "index_accounts_on_user_id"
    t.check_constraint "account_type::text = ANY (ARRAY['asset'::character varying, 'liability'::character varying, 'equity'::character varying, 'income'::character varying, 'expense'::character varying]::text[])", name: "check_accounts_account_type"
  end

  create_table "charges", force: :cascade do |t|
    t.bigint "amount_cents", null: false
    t.date "charge_date", null: false
    t.string "charge_kind", null: false
    t.datetime "created_at", null: false
    t.string "description"
    t.date "due_on", null: false
    t.datetime "posted_at"
    t.bigint "rent_term_id"
    t.date "service_period_end"
    t.date "service_period_start"
    t.bigint "source_expense_id"
    t.bigint "superseded_by_id"
    t.bigint "tenancy_id", null: false
    t.datetime "updated_at", null: false
    t.datetime "voided_at"
    t.index ["charge_date"], name: "index_charges_on_charge_date"
    t.index ["charge_kind"], name: "index_charges_on_charge_kind"
    t.index ["due_on"], name: "index_charges_on_due_on"
    t.index ["rent_term_id"], name: "index_charges_on_rent_term_id"
    t.index ["service_period_start"], name: "index_charges_on_service_period_start"
    t.index ["source_expense_id"], name: "index_charges_on_source_expense_id"
    t.index ["superseded_by_id"], name: "index_charges_on_superseded_by_id"
    t.index ["tenancy_id", "service_period_start"], name: "index_charges_on_tenancy_and_service_period_for_live_rent", unique: true, where: "(((charge_kind)::text = 'rent'::text) AND (voided_at IS NULL))"
    t.index ["tenancy_id"], name: "index_charges_on_tenancy_id"
    t.index ["voided_at"], name: "index_charges_on_voided_at"
    t.check_constraint "amount_cents > 0", name: "charges_amount_cents_positive"
    t.check_constraint "charge_kind::text = ANY (ARRAY['rent'::character varying, 'late_fee'::character varying, 'reimbursement'::character varying, 'other'::character varying]::text[])", name: "charges_charge_kind_valid"
    t.check_constraint "service_period_end IS NULL OR service_period_start IS NULL OR service_period_end >= service_period_start", name: "charges_service_period_valid"
  end

  create_table "expenses", force: :cascade do |t|
    t.bigint "amount_cents", null: false
    t.datetime "created_at", null: false
    t.string "description"
    t.string "expense_kind", null: false
    t.string "external_reference"
    t.date "paid_on", null: false
    t.datetime "posted_at"
    t.bigint "property_id", null: false
    t.bigint "rentable_unit_id"
    t.bigint "superseded_by_id"
    t.datetime "updated_at", null: false
    t.string "vendor_name"
    t.datetime "voided_at"
    t.index ["expense_kind"], name: "index_expenses_on_expense_kind"
    t.index ["paid_on"], name: "index_expenses_on_paid_on"
    t.index ["property_id", "paid_on"], name: "index_expenses_on_property_id_and_paid_on"
    t.index ["property_id"], name: "index_expenses_on_property_id"
    t.index ["rentable_unit_id"], name: "index_expenses_on_rentable_unit_id"
    t.index ["superseded_by_id"], name: "index_expenses_on_superseded_by_id"
    t.index ["superseded_by_id"], name: "index_expenses_on_superseded_by_id_unique", unique: true, where: "(superseded_by_id IS NOT NULL)"
    t.index ["voided_at"], name: "index_expenses_on_voided_at"
    t.check_constraint "amount_cents > 0", name: "expenses_amount_cents_positive"
    t.check_constraint "expense_kind::text = ANY (ARRAY['advertising'::character varying, 'auto_and_travel'::character varying, 'cleaning_and_maintenance'::character varying, 'commissions'::character varying, 'insurance'::character varying, 'legal_and_professional'::character varying, 'management'::character varying, 'mortgage_interest'::character varying, 'other_interest'::character varying, 'repairs'::character varying, 'supplies'::character varying, 'taxes'::character varying, 'utilities'::character varying, 'other'::character varying]::text[])", name: "expenses_expense_kind_valid"
  end

  create_table "journal_entries", force: :cascade do |t|
    t.datetime "created_at", null: false
    t.string "description"
    t.string "event_type", null: false
    t.date "occurred_on", null: false
    t.datetime "posted_at", null: false
    t.bigint "reversal_of_id"
    t.bigint "source_id", null: false
    t.string "source_type", null: false
    t.bigint "user_id", null: false
    t.index ["occurred_on"], name: "index_journal_entries_on_occurred_on"
    t.index ["reversal_of_id"], name: "idx_journal_entries_single_reversal", unique: true, where: "(reversal_of_id IS NOT NULL)"
    t.index ["user_id", "source_type", "source_id", "event_type"], name: "idx_journal_entries_source_event", unique: true
    t.index ["user_id"], name: "index_journal_entries_on_user_id"
    t.check_constraint "source_id > 0", name: "check_journal_entries_source_id_positive"
  end

  create_table "parties", force: :cascade do |t|
    t.datetime "created_at", null: false
    t.string "display_name", null: false
    t.string "email_address"
    t.string "mailing_address"
    t.string "party_type", null: false
    t.string "phone_number"
    t.datetime "updated_at", null: false
    t.bigint "user_id", null: false
    t.index ["user_id"], name: "index_parties_on_user_id"
  end

  create_table "party_aliases", force: :cascade do |t|
    t.string "alias_name", null: false
    t.datetime "created_at", null: false
    t.bigint "party_id", null: false
    t.datetime "updated_at", null: false
    t.index "party_id, lower((alias_name)::text)", name: "index_tenant_aliases_on_tenant_id_and_lower_alias_name", unique: true
    t.index ["party_id"], name: "index_party_aliases_on_party_id"
  end

  create_table "payment_documents", force: :cascade do |t|
    t.string "attachment_content_type"
    t.binary "attachment_file"
    t.string "attachment_filename"
    t.datetime "created_at", null: false
    t.text "error_message"
    t.string "status", default: "processing", null: false
    t.datetime "updated_at", null: false
    t.bigint "user_id", null: false
    t.index ["user_id"], name: "index_payment_documents_on_user_id"
  end

  create_table "payment_ingestions", force: :cascade do |t|
    t.decimal "amount", precision: 12, scale: 2
    t.datetime "created_at", null: false
    t.text "error_message"
    t.bigint "party_id"
    t.string "payer_name"
    t.string "payer_username"
    t.date "payment_date"
    t.bigint "payment_document_id"
    t.string "payment_method"
    t.text "raw_text"
    t.bigint "receipt_id"
    t.string "receipt_type"
    t.string "source", null: false
    t.string "status", default: "pending", null: false
    t.bigint "tenancy_id"
    t.string "transaction_number"
    t.datetime "updated_at", null: false
    t.bigint "user_id", null: false
    t.index ["party_id"], name: "index_payment_ingestions_on_party_id"
    t.index ["payment_document_id"], name: "index_payment_ingestions_on_payment_document_id"
    t.index ["receipt_id"], name: "index_payment_ingestions_on_receipt_id"
    t.index ["tenancy_id"], name: "index_payment_ingestions_on_tenancy_id"
    t.index ["user_id", "payment_method", "transaction_number"], name: "idx_payment_ingestions_dup_check"
    t.index ["user_id"], name: "index_payment_ingestions_on_user_id"
  end

  create_table "postings", force: :cascade do |t|
    t.bigint "account_id", null: false
    t.bigint "amount_cents", null: false
    t.datetime "created_at", null: false
    t.bigint "journal_entry_id", null: false
    t.string "memo"
    t.bigint "party_id"
    t.bigint "property_id"
    t.bigint "rentable_unit_id"
    t.bigint "tenancy_id"
    t.index ["account_id", "property_id"], name: "index_postings_on_account_id_and_property_id"
    t.index ["account_id", "tenancy_id"], name: "index_postings_on_account_id_and_tenancy_id"
    t.index ["account_id"], name: "index_postings_on_account_id"
    t.index ["journal_entry_id"], name: "index_postings_on_journal_entry_id"
    t.index ["party_id"], name: "index_postings_on_party_id"
    t.index ["property_id"], name: "index_postings_on_property_id"
    t.index ["rentable_unit_id"], name: "index_postings_on_rentable_unit_id"
    t.index ["tenancy_id"], name: "index_postings_on_tenancy_id"
    t.check_constraint "amount_cents <> 0", name: "check_postings_amount_cents_nonzero"
  end

  create_table "properties", force: :cascade do |t|
    t.string "address", null: false
    t.string "asset_type", null: false
    t.datetime "created_at", null: false
    t.integer "square_footage"
    t.datetime "updated_at", null: false
    t.bigint "user_id", null: false
    t.index ["user_id"], name: "index_properties_on_user_id"
  end

  create_table "receipts", force: :cascade do |t|
    t.bigint "amount_cents", null: false
    t.datetime "created_at", null: false
    t.string "external_reference"
    t.text "memo"
    t.bigint "payer_party_id", null: false
    t.string "payment_method", null: false
    t.timestamptz "posted_at"
    t.date "received_on", null: false
    t.bigint "superseded_by_id"
    t.bigint "tenancy_id", null: false
    t.datetime "updated_at", null: false
    t.bigint "user_id", null: false
    t.timestamptz "voided_at"
    t.index ["payer_party_id"], name: "index_receipts_on_payer_party_id"
    t.index ["received_on"], name: "index_receipts_on_received_on"
    t.index ["superseded_by_id"], name: "index_receipts_on_superseded_by_id"
    t.index ["superseded_by_id"], name: "index_receipts_on_superseded_by_id_unique", unique: true, where: "(superseded_by_id IS NOT NULL)"
    t.index ["tenancy_id"], name: "index_receipts_on_tenancy_id"
    t.index ["user_id", "payment_method", "external_reference"], name: "index_receipts_on_user_method_external_ref_active", unique: true, where: "((external_reference IS NOT NULL) AND (voided_at IS NULL))"
    t.index ["user_id"], name: "index_receipts_on_user_id"
    t.index ["voided_at"], name: "index_receipts_on_voided_at"
    t.check_constraint "amount_cents > 0", name: "receipts_amount_cents_positive"
  end

  create_table "rent_terms", force: :cascade do |t|
    t.bigint "amount_cents", null: false
    t.datetime "created_at", null: false
    t.integer "due_day", default: 1, null: false
    t.date "effective_from", null: false
    t.date "effective_until"
    t.string "frequency", default: "monthly", null: false
    t.bigint "tenancy_id", null: false
    t.datetime "updated_at", null: false
    t.index ["tenancy_id", "effective_from"], name: "index_rent_terms_on_tenancy_id_and_effective_from", unique: true
    t.index ["tenancy_id"], name: "index_rent_terms_on_tenancy_id"
  end

  create_table "rentable_units", force: :cascade do |t|
    t.boolean "active", default: true, null: false
    t.datetime "created_at", null: false
    t.string "name", null: false
    t.bigint "property_id", null: false
    t.integer "square_footage"
    t.string "unit_identifier"
    t.datetime "updated_at", null: false
    t.index "property_id, lower((unit_identifier)::text)", name: "index_rentable_units_on_property_id_and_lower_identifier", unique: true, where: "(unit_identifier IS NOT NULL)"
    t.index ["property_id"], name: "index_rentable_units_on_property_id"
  end

  create_table "security_deposit_transactions", force: :cascade do |t|
    t.bigint "amount_cents", null: false
    t.bigint "charge_id"
    t.datetime "created_at", null: false
    t.string "external_reference"
    t.text "memo"
    t.date "occurred_on", null: false
    t.bigint "party_id"
    t.datetime "posted_at"
    t.bigint "security_deposit_id", null: false
    t.bigint "superseded_by_id"
    t.string "transaction_kind", null: false
    t.datetime "updated_at", null: false
    t.datetime "voided_at"
    t.index ["charge_id"], name: "index_security_deposit_transactions_on_charge_id"
    t.index ["occurred_on"], name: "index_security_deposit_transactions_on_occurred_on"
    t.index ["party_id"], name: "index_security_deposit_transactions_on_party_id"
    t.index ["security_deposit_id", "transaction_kind"], name: "index_sdt_on_deposit_and_kind"
    t.index ["security_deposit_id"], name: "index_security_deposit_transactions_on_security_deposit_id"
    t.index ["superseded_by_id"], name: "index_sdt_on_unique_superseded_by_id", unique: true, where: "(superseded_by_id IS NOT NULL)"
    t.index ["superseded_by_id"], name: "index_security_deposit_transactions_on_superseded_by_id"
    t.index ["voided_at"], name: "index_security_deposit_transactions_on_voided_at"
    t.check_constraint "amount_cents > 0", name: "security_deposit_transactions_amount_cents_positive"
    t.check_constraint "transaction_kind::text = ANY (ARRAY['received'::character varying, 'refunded'::character varying, 'applied'::character varying]::text[])", name: "security_deposit_transactions_kind_check"
  end

  create_table "security_deposits", force: :cascade do |t|
    t.datetime "created_at", null: false
    t.date "due_on", null: false
    t.bigint "required_amount_cents", null: false
    t.bigint "tenancy_id", null: false
    t.datetime "updated_at", null: false
    t.index ["tenancy_id"], name: "index_security_deposits_on_tenancy_id", unique: true
    t.check_constraint "required_amount_cents > 0", name: "security_deposits_required_amount_cents_positive"
  end

  create_table "sessions", force: :cascade do |t|
    t.datetime "created_at", null: false
    t.string "ip_address"
    t.datetime "updated_at", null: false
    t.string "user_agent"
    t.bigint "user_id", null: false
    t.index ["user_id"], name: "index_sessions_on_user_id"
  end

  create_table "solid_queue_blocked_executions", force: :cascade do |t|
    t.string "concurrency_key", null: false
    t.datetime "created_at", null: false
    t.datetime "expires_at", null: false
    t.bigint "job_id", null: false
    t.integer "priority", default: 0, null: false
    t.string "queue_name", null: false
    t.index ["concurrency_key", "priority", "job_id"], name: "index_solid_queue_blocked_executions_for_release"
    t.index ["expires_at", "concurrency_key"], name: "index_solid_queue_blocked_executions_for_maintenance"
    t.index ["job_id"], name: "index_solid_queue_blocked_executions_on_job_id", unique: true
  end

  create_table "solid_queue_claimed_executions", force: :cascade do |t|
    t.datetime "created_at", null: false
    t.bigint "job_id", null: false
    t.bigint "process_id"
    t.index ["job_id"], name: "index_solid_queue_claimed_executions_on_job_id", unique: true
    t.index ["process_id", "job_id"], name: "index_solid_queue_claimed_executions_on_process_id_and_job_id"
  end

  create_table "solid_queue_failed_executions", force: :cascade do |t|
    t.datetime "created_at", null: false
    t.text "error"
    t.bigint "job_id", null: false
    t.index ["job_id"], name: "index_solid_queue_failed_executions_on_job_id", unique: true
  end

  create_table "solid_queue_jobs", force: :cascade do |t|
    t.string "active_job_id"
    t.text "arguments"
    t.string "class_name", null: false
    t.string "concurrency_key"
    t.datetime "created_at", null: false
    t.datetime "finished_at"
    t.integer "priority", default: 0, null: false
    t.string "queue_name", null: false
    t.datetime "scheduled_at"
    t.datetime "updated_at", null: false
    t.index ["active_job_id"], name: "index_solid_queue_jobs_on_active_job_id"
    t.index ["class_name"], name: "index_solid_queue_jobs_on_class_name"
    t.index ["finished_at"], name: "index_solid_queue_jobs_on_finished_at"
    t.index ["queue_name", "finished_at"], name: "index_solid_queue_jobs_for_filtering"
    t.index ["scheduled_at", "finished_at"], name: "index_solid_queue_jobs_for_alerting"
  end

  create_table "solid_queue_pauses", force: :cascade do |t|
    t.datetime "created_at", null: false
    t.string "queue_name", null: false
    t.index ["queue_name"], name: "index_solid_queue_pauses_on_queue_name", unique: true
  end

  create_table "solid_queue_processes", force: :cascade do |t|
    t.datetime "created_at", null: false
    t.string "hostname"
    t.string "kind", null: false
    t.datetime "last_heartbeat_at", null: false
    t.text "metadata"
    t.string "name", null: false
    t.integer "pid", null: false
    t.bigint "supervisor_id"
    t.index ["last_heartbeat_at"], name: "index_solid_queue_processes_on_last_heartbeat_at"
    t.index ["name", "supervisor_id"], name: "index_solid_queue_processes_on_name_and_supervisor_id", unique: true
    t.index ["supervisor_id"], name: "index_solid_queue_processes_on_supervisor_id"
  end

  create_table "solid_queue_ready_executions", force: :cascade do |t|
    t.datetime "created_at", null: false
    t.bigint "job_id", null: false
    t.integer "priority", default: 0, null: false
    t.string "queue_name", null: false
    t.index ["job_id"], name: "index_solid_queue_ready_executions_on_job_id", unique: true
    t.index ["priority", "job_id"], name: "index_solid_queue_poll_all"
    t.index ["queue_name", "priority", "job_id"], name: "index_solid_queue_poll_by_queue"
  end

  create_table "solid_queue_recurring_executions", force: :cascade do |t|
    t.datetime "created_at", null: false
    t.bigint "job_id", null: false
    t.datetime "run_at", null: false
    t.string "task_key", null: false
    t.index ["job_id"], name: "index_solid_queue_recurring_executions_on_job_id", unique: true
    t.index ["task_key", "run_at"], name: "index_solid_queue_recurring_executions_on_task_key_and_run_at", unique: true
  end

  create_table "solid_queue_recurring_tasks", force: :cascade do |t|
    t.text "arguments"
    t.string "class_name"
    t.string "command", limit: 2048
    t.datetime "created_at", null: false
    t.text "description"
    t.string "key", null: false
    t.integer "priority", default: 0
    t.string "queue_name"
    t.string "schedule", null: false
    t.boolean "static", default: true, null: false
    t.datetime "updated_at", null: false
    t.index ["key"], name: "index_solid_queue_recurring_tasks_on_key", unique: true
    t.index ["static"], name: "index_solid_queue_recurring_tasks_on_static"
  end

  create_table "solid_queue_scheduled_executions", force: :cascade do |t|
    t.datetime "created_at", null: false
    t.bigint "job_id", null: false
    t.integer "priority", default: 0, null: false
    t.string "queue_name", null: false
    t.datetime "scheduled_at", null: false
    t.index ["job_id"], name: "index_solid_queue_scheduled_executions_on_job_id", unique: true
    t.index ["scheduled_at", "priority", "job_id"], name: "index_solid_queue_dispatch_all"
  end

  create_table "solid_queue_semaphores", force: :cascade do |t|
    t.datetime "created_at", null: false
    t.datetime "expires_at", null: false
    t.string "key", null: false
    t.datetime "updated_at", null: false
    t.integer "value", default: 1, null: false
    t.index ["expires_at"], name: "index_solid_queue_semaphores_on_expires_at"
    t.index ["key", "value"], name: "index_solid_queue_semaphores_on_key_and_value"
    t.index ["key"], name: "index_solid_queue_semaphores_on_key", unique: true
  end

  create_table "tenancies", force: :cascade do |t|
    t.string "agreement_type", null: false
    t.date "commencement_date", null: false
    t.datetime "created_at", null: false
    t.integer "late_period_days", default: 0, null: false
    t.bigint "rentable_unit_id", null: false
    t.date "termination_date"
    t.datetime "updated_at", null: false
    t.index ["rentable_unit_id"], name: "index_tenancies_on_rentable_unit_id"
  end

  create_table "tenancy_parties", force: :cascade do |t|
    t.datetime "created_at", null: false
    t.date "effective_from", null: false
    t.date "effective_until"
    t.bigint "party_id", null: false
    t.string "role", null: false
    t.bigint "tenancy_id", null: false
    t.datetime "updated_at", null: false
    t.index ["party_id"], name: "index_tenancy_parties_on_party_id"
    t.index ["tenancy_id", "party_id", "role", "effective_from"], name: "idx_tenancy_parties_exact_dup", unique: true
    t.index ["tenancy_id"], name: "index_tenancy_parties_on_tenancy_id"
  end

  create_table "users", force: :cascade do |t|
    t.datetime "created_at", null: false
    t.string "email", null: false
    t.string "password_digest", null: false
    t.string "timezone", default: "UTC", null: false
    t.datetime "updated_at", null: false
    t.index ["email"], name: "index_users_on_email", unique: true
  end

  add_foreign_key "accounts", "users"
  add_foreign_key "charges", "charges", column: "superseded_by_id"
  add_foreign_key "charges", "expenses", column: "source_expense_id"
  add_foreign_key "charges", "rent_terms"
  add_foreign_key "charges", "tenancies"
  add_foreign_key "expenses", "expenses", column: "superseded_by_id"
  add_foreign_key "expenses", "properties"
  add_foreign_key "expenses", "rentable_units"
  add_foreign_key "journal_entries", "journal_entries", column: "reversal_of_id"
  add_foreign_key "journal_entries", "users"
  add_foreign_key "parties", "users"
  add_foreign_key "party_aliases", "parties"
  add_foreign_key "payment_documents", "users"
  add_foreign_key "payment_ingestions", "parties"
  add_foreign_key "payment_ingestions", "payment_documents"
  add_foreign_key "payment_ingestions", "receipts"
  add_foreign_key "payment_ingestions", "tenancies"
  add_foreign_key "payment_ingestions", "users"
  add_foreign_key "postings", "accounts"
  add_foreign_key "postings", "journal_entries"
  add_foreign_key "postings", "parties"
  add_foreign_key "postings", "properties"
  add_foreign_key "postings", "rentable_units"
  add_foreign_key "postings", "tenancies"
  add_foreign_key "properties", "users"
  add_foreign_key "receipts", "parties", column: "payer_party_id"
  add_foreign_key "receipts", "receipts", column: "superseded_by_id"
  add_foreign_key "receipts", "tenancies"
  add_foreign_key "receipts", "users"
  add_foreign_key "rent_terms", "tenancies"
  add_foreign_key "rentable_units", "properties"
  add_foreign_key "security_deposit_transactions", "charges"
  add_foreign_key "security_deposit_transactions", "parties"
  add_foreign_key "security_deposit_transactions", "security_deposit_transactions", column: "superseded_by_id"
  add_foreign_key "security_deposit_transactions", "security_deposits"
  add_foreign_key "security_deposits", "tenancies"
  add_foreign_key "sessions", "users"
  add_foreign_key "solid_queue_blocked_executions", "solid_queue_jobs", column: "job_id", on_delete: :cascade
  add_foreign_key "solid_queue_claimed_executions", "solid_queue_jobs", column: "job_id", on_delete: :cascade
  add_foreign_key "solid_queue_failed_executions", "solid_queue_jobs", column: "job_id", on_delete: :cascade
  add_foreign_key "solid_queue_ready_executions", "solid_queue_jobs", column: "job_id", on_delete: :cascade
  add_foreign_key "solid_queue_recurring_executions", "solid_queue_jobs", column: "job_id", on_delete: :cascade
  add_foreign_key "solid_queue_scheduled_executions", "solid_queue_jobs", column: "job_id", on_delete: :cascade
  add_foreign_key "tenancies", "rentable_units"
  add_foreign_key "tenancy_parties", "parties"
  add_foreign_key "tenancy_parties", "tenancies"
end
