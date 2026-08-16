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

ActiveRecord::Schema[8.1].define(version: 2026_08_16_000001) do
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

  create_table "expenses", force: :cascade do |t|
    t.decimal "amount", precision: 12, scale: 2
    t.string "category"
    t.datetime "created_at", null: false
    t.string "description"
    t.date "expense_date"
    t.bigint "property_id", null: false
    t.datetime "updated_at", null: false
    t.index ["property_id"], name: "index_expenses_on_property_id"
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
    t.string "receipt_type"
    t.string "source", null: false
    t.string "status", default: "pending", null: false
    t.bigint "tenancy_id"
    t.bigint "tenant_payment_id"
    t.string "transaction_number"
    t.datetime "updated_at", null: false
    t.bigint "user_id", null: false
    t.index ["party_id"], name: "index_payment_ingestions_on_party_id"
    t.index ["payment_document_id"], name: "index_payment_ingestions_on_payment_document_id"
    t.index ["tenancy_id"], name: "index_payment_ingestions_on_tenancy_id"
    t.index ["tenant_payment_id"], name: "index_payment_ingestions_on_tenant_payment_id"
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

  create_table "scheduled_rents", force: :cascade do |t|
    t.decimal "amount", precision: 12, scale: 2
    t.datetime "created_at", null: false
    t.date "due_date"
    t.bigint "tenancy_id", null: false
    t.datetime "updated_at", null: false
    t.index ["tenancy_id"], name: "index_scheduled_rents_on_tenancy_id"
  end

  create_table "sessions", force: :cascade do |t|
    t.datetime "created_at", null: false
    t.string "ip_address"
    t.datetime "updated_at", null: false
    t.string "user_agent"
    t.bigint "user_id", null: false
    t.index ["user_id"], name: "index_sessions_on_user_id"
  end

  create_table "solid_cable_messages", force: :cascade do |t|
    t.binary "channel", null: false
    t.bigint "channel_hash", null: false
    t.datetime "created_at", null: false
    t.binary "payload", null: false
    t.index ["channel"], name: "index_solid_cable_messages_on_channel"
    t.index ["channel_hash"], name: "index_solid_cable_messages_on_channel_hash"
    t.index ["created_at"], name: "index_solid_cable_messages_on_created_at"
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

  create_table "tenant_charges", force: :cascade do |t|
    t.decimal "amount", precision: 12, scale: 2, null: false
    t.date "charge_date", null: false
    t.datetime "created_at", null: false
    t.string "description"
    t.bigint "expense_id", null: false
    t.bigint "tenancy_id", null: false
    t.datetime "updated_at", null: false
    t.index ["expense_id"], name: "index_tenant_charges_on_expense_id"
    t.index ["tenancy_id"], name: "index_tenant_charges_on_tenancy_id"
  end

  create_table "tenant_payments", force: :cascade do |t|
    t.decimal "amount", precision: 12, scale: 2, null: false
    t.datetime "created_at", null: false
    t.date "payment_date", null: false
    t.string "payment_method", null: false
    t.bigint "tenancy_id", null: false
    t.string "transaction_number"
    t.datetime "updated_at", null: false
    t.bigint "user_id", null: false
    t.index ["tenancy_id"], name: "index_tenant_payments_on_tenancy_id"
    t.index ["user_id", "payment_method", "transaction_number"], name: "index_tenant_payments_on_user_payment_method_transaction_number", unique: true, where: "(transaction_number IS NOT NULL)"
    t.index ["user_id"], name: "index_tenant_payments_on_user_id"
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
  add_foreign_key "expenses", "properties"
  add_foreign_key "journal_entries", "journal_entries", column: "reversal_of_id"
  add_foreign_key "journal_entries", "users"
  add_foreign_key "parties", "users"
  add_foreign_key "party_aliases", "parties"
  add_foreign_key "payment_documents", "users"
  add_foreign_key "payment_ingestions", "parties"
  add_foreign_key "payment_ingestions", "payment_documents"
  add_foreign_key "payment_ingestions", "tenancies"
  add_foreign_key "payment_ingestions", "tenant_payments"
  add_foreign_key "payment_ingestions", "users"
  add_foreign_key "postings", "accounts"
  add_foreign_key "postings", "journal_entries"
  add_foreign_key "postings", "parties"
  add_foreign_key "postings", "properties"
  add_foreign_key "postings", "rentable_units"
  add_foreign_key "postings", "tenancies"
  add_foreign_key "properties", "users"
  add_foreign_key "rent_terms", "tenancies"
  add_foreign_key "rentable_units", "properties"
  add_foreign_key "scheduled_rents", "tenancies"
  add_foreign_key "sessions", "users"
  add_foreign_key "tenancies", "rentable_units"
  add_foreign_key "tenancy_parties", "parties"
  add_foreign_key "tenancy_parties", "tenancies"
  add_foreign_key "tenant_charges", "expenses"
  add_foreign_key "tenant_charges", "tenancies"
  add_foreign_key "tenant_payments", "tenancies"
  add_foreign_key "tenant_payments", "users"
end
