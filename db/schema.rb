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

ActiveRecord::Schema[8.1].define(version: 2026_08_22_000004) do
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
    t.integer "property_id", null: false
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

  create_table "imported_transactions", force: :cascade do |t|
    t.bigint "amount_cents"
    t.bigint "confirmed_source_id"
    t.string "confirmed_source_type"
    t.datetime "created_at", null: false
    t.text "error_message"
    t.string "external_reference"
    t.bigint "matched_party_id"
    t.bigint "matched_tenancy_id"
    t.date "occurred_on"
    t.string "payer_name"
    t.string "payer_username"
    t.string "payment_method"
    t.text "raw_text"
    t.string "source", null: false
    t.bigint "source_document_id", null: false
    t.string "status", default: "pending", null: false
    t.string "transaction_kind", default: "unknown", null: false
    t.datetime "updated_at", null: false
    t.bigint "user_id", null: false
    t.index ["confirmed_source_type", "confirmed_source_id"], name: "idx_imported_txns_confirmed_source", unique: true, where: "(confirmed_source_id IS NOT NULL)"
    t.index ["matched_party_id"], name: "index_imported_transactions_on_matched_party_id"
    t.index ["matched_tenancy_id"], name: "index_imported_transactions_on_matched_tenancy_id"
    t.index ["source_document_id"], name: "index_imported_transactions_on_source_document_id"
    t.index ["user_id", "source", "payment_method", "external_reference"], name: "idx_imported_txns_user_src_method_ext_ref", unique: true, where: "((payment_method IS NOT NULL) AND (external_reference IS NOT NULL))"
    t.index ["user_id"], name: "index_imported_transactions_on_user_id"
    t.check_constraint "amount_cents IS NULL OR amount_cents > 0", name: "imported_transactions_amount_cents_check"
    t.check_constraint "status::text = 'confirmed'::text AND confirmed_source_type IS NOT NULL AND confirmed_source_id IS NOT NULL OR status::text <> 'confirmed'::text AND confirmed_source_type IS NULL AND confirmed_source_id IS NULL", name: "imported_transactions_confirmed_source_check"
    t.check_constraint "status::text = ANY (ARRAY['pending'::character varying, 'matched'::character varying, 'unmatched'::character varying, 'ambiguous'::character varying, 'confirmed'::character varying, 'failed'::character varying]::text[])", name: "imported_transactions_status_check"
    t.check_constraint "transaction_kind::text = ANY (ARRAY['unknown'::character varying, 'tenant_receipt'::character varying, 'security_deposit'::character varying]::text[])", name: "imported_transactions_kind_check"
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
    t.index ["user_id", "occurred_on", "id"], name: "index_journal_entries_on_user_id_and_occurred_on_and_id"
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
    t.integer "user_id", null: false
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
    t.index ["account_id", "journal_entry_id"], name: "index_postings_on_account_id_and_journal_entry_id"
    t.index ["account_id", "property_id"], name: "index_postings_on_account_id_and_property_id"
    t.index ["account_id", "tenancy_id"], name: "index_postings_on_account_id_and_tenancy_id"
    t.index ["account_id"], name: "index_postings_on_account_id"
    t.index ["journal_entry_id"], name: "index_postings_on_journal_entry_id"
    t.index ["party_id"], name: "index_postings_on_party_id"
    t.index ["property_id", "journal_entry_id"], name: "index_postings_on_property_id_and_journal_entry_id"
    t.index ["property_id"], name: "index_postings_on_property_id"
    t.index ["rentable_unit_id"], name: "index_postings_on_rentable_unit_id"
    t.index ["tenancy_id", "journal_entry_id"], name: "index_postings_on_tenancy_id_and_journal_entry_id"
    t.index ["tenancy_id"], name: "index_postings_on_tenancy_id"
    t.check_constraint "amount_cents <> 0", name: "check_postings_amount_cents_nonzero"
  end

  create_table "properties", force: :cascade do |t|
    t.string "address", null: false
    t.string "asset_type", null: false
    t.datetime "created_at", null: false
    t.integer "square_footage"
    t.datetime "updated_at", null: false
    t.integer "user_id", null: false
    t.index ["user_id"], name: "index_properties_on_user_id"
  end

  create_table "property_tax_profiles", force: :cascade do |t|
    t.datetime "created_at", null: false
    t.string "other_description"
    t.bigint "property_id", null: false
    t.string "schedule_e_property_type", null: false
    t.integer "tax_year", null: false
    t.datetime "updated_at", null: false
    t.index ["property_id", "tax_year"], name: "index_property_tax_profiles_on_property_id_and_tax_year", unique: true
    t.index ["property_id"], name: "index_property_tax_profiles_on_property_id"
    t.check_constraint "tax_year >= 1901 AND tax_year <= 2099", name: "check_property_tax_profiles_tax_year_range"
  end

  create_table "property_tax_review_resolutions", force: :cascade do |t|
    t.datetime "created_at", null: false
    t.bigint "journal_entry_id", null: false
    t.text "notes"
    t.bigint "property_id", null: false
    t.string "schedule_e_category"
    t.integer "tax_year", null: false
    t.string "treatment", null: false
    t.datetime "updated_at", null: false
    t.index ["journal_entry_id"], name: "index_property_tax_review_resolutions_on_journal_entry_id"
    t.index ["property_id", "tax_year", "journal_entry_id"], name: "idx_tax_review_resolutions_on_prop_year_entry", unique: true
    t.index ["property_id"], name: "index_property_tax_review_resolutions_on_property_id"
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
    t.integer "user_id", null: false
    t.index ["user_id"], name: "index_sessions_on_user_id"
  end

  create_table "source_documents", force: :cascade do |t|
    t.string "attachment_content_type"
    t.binary "attachment_file"
    t.string "attachment_filename"
    t.string "attachment_sha256", null: false
    t.datetime "created_at", null: false
    t.string "document_type", default: "unknown", null: false
    t.text "error_message"
    t.string "status", default: "processing", null: false
    t.datetime "updated_at", null: false
    t.bigint "user_id", null: false
    t.index ["user_id", "attachment_sha256"], name: "idx_source_documents_user_id_sha256", unique: true
    t.index ["user_id"], name: "index_source_documents_on_user_id"
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
    t.integer "party_id", null: false
    t.string "role", null: false
    t.integer "tenancy_id", null: false
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
  add_foreign_key "imported_transactions", "parties", column: "matched_party_id"
  add_foreign_key "imported_transactions", "source_documents"
  add_foreign_key "imported_transactions", "tenancies", column: "matched_tenancy_id"
  add_foreign_key "imported_transactions", "users"
  add_foreign_key "journal_entries", "journal_entries", column: "reversal_of_id"
  add_foreign_key "journal_entries", "users"
  add_foreign_key "parties", "users"
  add_foreign_key "party_aliases", "parties"
  add_foreign_key "postings", "accounts"
  add_foreign_key "postings", "journal_entries"
  add_foreign_key "postings", "parties"
  add_foreign_key "postings", "properties"
  add_foreign_key "postings", "rentable_units"
  add_foreign_key "postings", "tenancies"
  add_foreign_key "properties", "users"
  add_foreign_key "property_tax_profiles", "properties"
  add_foreign_key "property_tax_review_resolutions", "journal_entries"
  add_foreign_key "property_tax_review_resolutions", "properties"
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
  add_foreign_key "source_documents", "users"
  add_foreign_key "tenancies", "rentable_units"
  add_foreign_key "tenancy_parties", "parties"
  add_foreign_key "tenancy_parties", "tenancies"
end
