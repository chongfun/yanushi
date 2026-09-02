require "rails_helper"

RSpec.describe "Inbox", type: :system do
  let(:user) { create(:user) }
  let(:property) { create(:property, user: user, address: "742 Evergreen Terrace") }
  let(:unit) { create(:rentable_unit, property: property, unit_identifier: "Main") }
  let(:party) { create(:party, user: user, display_name: "Homer Simpson") }
  let!(:tenancy) do
    t = create(:tenancy, rentable_unit: unit, agreement_type: "month_to_month", commencement_date: Date.new(2025, 1, 1), termination_date: nil)
    create(:tenancy_party, tenancy: t, party: party, role: "tenant")
    t
  end
  let(:source_document) { create(:source_document, user: user, status: "success", attachment_filename: "chase_aug.pdf") }

  before do
    Accounting::ChartOfAccounts.ensure_for(user)
    visit new_session_path
    fill_in "email", with: user.email
    fill_in "password", with: "password"
    click_on "Sign in"
    expect(page).to have_text("Overview")
  end

  after do
    if page.driver.is_a?(Capybara::Selenium::Driver)
      page.current_window.resize_to(1280, 800)
    end
  end

  describe "wide-screen master/detail review loop", js: true do
    it "allows selecting stream-replaced queue rows, managing aria-current and focus, and completing review" do
      page.current_window.resize_to(1280, 800)

      txn1 = create(
        :imported_transaction,
        user: user,
        source_document: source_document,
        status: "matched",
        transaction_kind: "tenant_receipt",
        matched_party: party,
        matched_tenancy: tenancy,
        payer_name: "Homer Simpson",
        amount_cents: 100_000,
        occurred_on: Date.new(2026, 8, 19),
        payment_method: "zelle",
        external_reference: "ZL-001"
      )

      txn2 = create(
        :imported_transaction,
        user: user,
        source_document: source_document,
        status: "matched",
        transaction_kind: "tenant_receipt",
        matched_party: party,
        matched_tenancy: tenancy,
        payer_name: "Homer Simpson",
        amount_cents: 200_000,
        occurred_on: Date.new(2026, 8, 20),
        payment_method: "zelle",
        external_reference: "ZL-002"
      )

      txn3 = create(
        :imported_transaction,
        user: user,
        source_document: source_document,
        status: "matched",
        transaction_kind: "tenant_receipt",
        matched_party: party,
        matched_tenancy: tenancy,
        payer_name: "Homer Simpson",
        amount_cents: 300_000,
        occurred_on: Date.new(2026, 8, 21),
        payment_method: "zelle",
        external_reference: "ZL-003"
      )

      visit inbox_path

      # Initial state: txn3 is auto-selected, queue has 3 items
      expect(page).to have_css("#sidebar_inbox_badge", text: "3")
      expect(page).to have_css("#imported_transaction_#{txn3.id}[aria-current='true']")
      within("#inbox_review") do
        expect(page).to have_content("$3,000.00")
      end

      # Confirm txn3 (Item A) -> stream removes txn3, stream-replaces txn2 (Item B) with selected: true
      page.execute_script("document.querySelector('#review_form_#{txn3.id}').requestSubmit()")

      expect(page).to have_content("Transaction confirmed and recorded successfully.")
      expect(page).to have_no_css("#imported_transaction_#{txn3.id}")
      expect(page).to have_css("#sidebar_inbox_badge", text: "2")
      expect(page).to have_css("#imported_transaction_#{txn2.id}[aria-current='true']")
      # Click txn1 (Item C)
      page.execute_script("document.querySelector('#imported_transaction_#{txn1.id}').click()")

      # Frame loads txn1 without full-page navigation
      expect(page).to have_current_path(inbox_path)
      within("#inbox_review") do
        expect(page).to have_content("$1,000.00")
      end
      expect(page).to have_css("#imported_transaction_#{txn1.id}[aria-current='true']")
      expect(page).to have_no_css("#imported_transaction_#{txn2.id}[aria-current='true']")

      # Click replaced row txn2 (Item B) again -> must load into frame, NOT full-page navigate
      page.execute_script("document.querySelector('#imported_transaction_#{txn2.id}').click()")

      expect(page).to have_current_path(inbox_path)
      within("#inbox_review") do
        expect(page).to have_content("$2,000.00")
      end
      expect(page).to have_css("#imported_transaction_#{txn2.id}[aria-current='true']")
      expect(page).to have_no_css("#imported_transaction_#{txn1.id}[aria-current='true']")

      # Confirm txn2
      page.execute_script("document.querySelector('#review_form_#{txn2.id}').requestSubmit()")

      expect(page).to have_content("Transaction confirmed and recorded successfully.")
      expect(page).to have_no_css("#imported_transaction_#{txn2.id}")
      expect(page).to have_css("#sidebar_inbox_badge", text: "1")
      expect(page).to have_css("#imported_transaction_#{txn1.id}[aria-current='true']")

      # Confirm txn1 -> caught up
      within("#inbox_review") do
        expect(page).to have_content("$1,000.00")
      end
      page.execute_script("document.querySelector('#review_form_#{txn1.id}').requestSubmit()")

      expect(page).to have_content("You’re caught up")
      expect(page).to have_content("No imported transactions need review.")
      expect(page).to have_no_css("#imported_transaction_#{txn1.id}")

      # Persisted state on reload
      page.refresh
      expect(page).to have_content("You’re caught up")
      expect(page).to have_no_css("#sidebar_inbox_badge .yn-count")
    end

    it "edits unclassified fields and confirms in a single atomic step" do
      page.current_window.resize_to(1280, 800)

      unmatched_txn = create(
        :imported_transaction,
        user: user,
        source_document: source_document,
        status: "unmatched",
        transaction_kind: "unknown",
        payer_name: "Unidentified Person",
        amount_cents: 175_000,
        occurred_on: Date.new(2026, 8, 22)
      )

      visit inbox_path
      expect(page).to have_css("#review_form_#{unmatched_txn.id}")

      # Fill in classification, payer, tenancy, payment method, reference
      select "Tenant receipt", from: "rev-kind-#{unmatched_txn.id}"
      select "Homer Simpson", from: "rev-party-#{unmatched_txn.id}"
      select "742 Evergreen Terrace — Main", from: "rev-tenancy-#{unmatched_txn.id}"
      page.execute_script("document.querySelector('#rev-method-#{unmatched_txn.id}').value = 'check'")
      page.execute_script("document.querySelector('#rev-ref-#{unmatched_txn.id}').value = 'CHK-777'")

      # Single click on Confirm receipt applies fields and confirms atomically
      page.execute_script("document.querySelector('#review_form_#{unmatched_txn.id}').requestSubmit(document.querySelector('#confirm_btn_#{unmatched_txn.id}'))")

      expect(page).to have_content("Transaction confirmed and recorded successfully.")
      expect(page).to have_content("You’re caught up")

      unmatched_txn.reload
      expect(unmatched_txn.status).to eq("confirmed")
      expect(unmatched_txn.transaction_kind).to eq("tenant_receipt")
      expect(unmatched_txn.payment_method).to eq("check")
      expect(unmatched_txn.external_reference).to eq("CHK-777")
      expect(unmatched_txn.matched_party).to eq(party)
      expect(unmatched_txn.matched_tenancy).to eq(tenancy)
      expect(unmatched_txn.confirmed_source).to be_a(Receipt)
      expect(unmatched_txn.confirmed_source.amount_cents).to eq(175_000)
    end

    it "dynamically updates the alias proposal when changing payer and persists the alias for the selected party" do
      page.current_window.resize_to(1280, 800)

      party_bob = create(:party, user: user, display_name: "Bob Belcher")

      txn = create(
        :imported_transaction,
        user: user,
        source_document: source_document,
        status: "matched",
        transaction_kind: "tenant_receipt",
        matched_party: party,
        matched_tenancy: tenancy,
        payer_name: "HOMER_SIMPSON_99",
        amount_cents: 100_000,
        occurred_on: Date.new(2026, 8, 20),
        payment_method: "zelle",
        external_reference: "ZL-ALIAS-01"
      )

      visit inbox_path
      expect(page).to have_css("#review_form_#{txn.id}")

      # Initial state: alias checkbox proposal names Homer Simpson
      expect(page).to have_content("Remember “HOMER_SIMPSON_99” as Homer Simpson for future imports")
      expect(find_field("create_alias")).to be_checked

      # User changes Payer to Bob Belcher
      select "Bob Belcher", from: "rev-party-#{txn.id}"

      # Live update: alias label immediately updates to Bob Belcher
      expect(page).to have_content("Remember “HOMER_SIMPSON_99” as Bob Belcher for future imports")
      expect(page).to have_no_content("as Homer Simpson for future imports")

      # Confirm transaction
      page.execute_script("document.querySelector('#review_form_#{txn.id}').requestSubmit(document.querySelector('#confirm_btn_#{txn.id}'))")

      expect(page).to have_content("Transaction confirmed and recorded successfully.")

      # Verify PartyAlias is created for Bob Belcher (party_bob), NOT Homer Simpson
      expect(PartyAlias.find_by(party: party_bob, alias_name: "HOMER_SIMPSON_99")).to be_present
      expect(PartyAlias.find_by(party: party, alias_name: "HOMER_SIMPSON_99")).to be_nil
    end

    it "dynamically switches alias proposal candidate when new party has existing alias and confirms the exact proposal" do
      page.current_window.resize_to(1280, 800)

      party_bob = create(:party, user: user, display_name: "Bob Belcher")
      # party_bob already has "HOMER_SIMPSON_99" as an alias, so proposed candidate for party_bob is "@homersimpson"
      create(:party_alias, party: party_bob, alias_name: "HOMER_SIMPSON_99")

      txn = create(
        :imported_transaction,
        user: user,
        source_document: source_document,
        status: "matched",
        transaction_kind: "tenant_receipt",
        matched_party: party,
        matched_tenancy: tenancy,
        payer_name: "HOMER_SIMPSON_99",
        payer_username: "@homersimpson",
        amount_cents: 100_000,
        occurred_on: Date.new(2026, 8, 20),
        payment_method: "zelle",
        external_reference: "ZL-ALIAS-02"
      )

      visit inbox_path
      expect(page).to have_css("#review_form_#{txn.id}")

      # Initial state for Homer Simpson: candidate is HOMER_SIMPSON_99
      expect(page).to have_content("Remember “HOMER_SIMPSON_99” as Homer Simpson for future imports")

      # User changes Payer to Bob Belcher (where HOMER_SIMPSON_99 is taken, so candidate is @homersimpson)
      select "Bob Belcher", from: "rev-party-#{txn.id}"

      # Live update: alias label immediately updates to "@homersimpson" as Bob Belcher
      expect(page).to have_content("Remember “@homersimpson” as Bob Belcher for future imports")
      expect(find("#rev_proposed_alias_#{txn.id}", visible: :all).value).to eq("@homersimpson")

      # Confirm transaction
      click_button "Confirm receipt"

      expect(page).to have_content("Transaction confirmed and recorded successfully.")

      # Verify @homersimpson alias was created for party_bob
      expect(PartyAlias.find_by(party: party_bob, alias_name: "@homersimpson")).to be_present
    end

    it "preserves unchecked alias checkbox across a 422 validation failure" do
      page.current_window.resize_to(1280, 800)

      invalid_txn = create(
        :imported_transaction,
        user: user,
        source_document: source_document,
        status: "matched",
        transaction_kind: "tenant_receipt",
        matched_party: party,
        matched_tenancy: tenancy,
        payment_method: "zelle",
        payer_name: "ALICE_PAYER_99",
        amount_cents: 50_000,
        occurred_on: Date.new(2026, 8, 22)
      )

      visit inbox_path
      expect(page).to have_css("#review_form_#{invalid_txn.id}")
      expect(find_field("create_alias")).to be_checked

      # User unchecks the Remember alias checkbox
      uncheck "create_alias"
      expect(find_field("create_alias")).not_to be_checked

      # Enter invalid reference to trigger 422 validation failure
      fill_in "rev-ref-#{invalid_txn.id}", with: "A" * 300

      # Submit confirmation
      click_button "Confirm receipt"

      # 422 error alert rendered into frame
      expect(page).to have_css("#form_error_alert")
      expect(page).to have_content("External reference is too long")

      # Checkbox remains unchecked across 422 rerender
      expect(find_field("create_alias")).not_to be_checked
    end

    it "dynamically updates primary button text and disabled state across Choose classification, Confirm receipt, and Confirm deposit" do
      page.current_window.resize_to(1280, 800)

      unit2 = create(:rentable_unit, property: property, unit_identifier: "Unit 2")
      deposit_tenancy = create(:tenancy, rentable_unit: unit2, agreement_type: "fixed_term", commencement_date: Date.new(2025, 1, 1), termination_date: Date.new(2026, 12, 31))
      create(:tenancy_party, tenancy: deposit_tenancy, party: party, role: "tenant")
      create(:security_deposit, tenancy: deposit_tenancy, required_amount_cents: 200_000)

      txn = create(
        :imported_transaction,
        user: user,
        source_document: source_document,
        status: "matched",
        transaction_kind: "unknown",
        matched_party: party,
        matched_tenancy: deposit_tenancy,
        amount_cents: 100_000,
        occurred_on: Date.new(2026, 8, 20),
        payment_method: "zelle",
        external_reference: "DEP-01"
      )

      visit inbox_path
      expect(page).to have_css("#review_form_#{txn.id}")

      # Initial state for unclassified: button says Choose classification and is disabled
      expect(find("#confirm_btn_#{txn.id}").text).to eq("Choose classification")
      expect(find("#confirm_btn_#{txn.id}")).to be_disabled

      # Switch Record as to Security deposit
      select "Security deposit", from: "rev-kind-#{txn.id}"

      # Button text dynamically updates to Confirm deposit and is enabled
      expect(find("#confirm_btn_#{txn.id}").text).to eq("Confirm deposit")
      expect(find("#confirm_btn_#{txn.id}")).not_to be_disabled

      # Switch to Tenant receipt
      select "Tenant receipt", from: "rev-kind-#{txn.id}"
      expect(find("#confirm_btn_#{txn.id}").text).to eq("Confirm receipt")
      expect(find("#confirm_btn_#{txn.id}")).not_to be_disabled

      # Switch back to Needs classification
      select "Needs classification", from: "rev-kind-#{txn.id}"
      expect(find("#confirm_btn_#{txn.id}").text).to eq("Choose classification")
      expect(find("#confirm_btn_#{txn.id}")).to be_disabled

      # Switch to Security deposit and confirm
      select "Security deposit", from: "rev-kind-#{txn.id}"
      click_button "Confirm deposit"

      expect(page).to have_content("Transaction confirmed and recorded successfully.")
      expect(page).to have_content("You’re caught up")

      txn.reload
      expect(txn.status).to eq("confirmed")
      expect(txn.transaction_kind).to eq("security_deposit")
      expect(txn.confirmed_source).to be_a(SecurityDepositTransaction)
    end

    it "focuses the validation problem or invalid control on 422 response" do
      page.current_window.resize_to(1280, 800)

      invalid_txn = create(
        :imported_transaction,
        user: user,
        source_document: source_document,
        status: "matched",
        transaction_kind: "tenant_receipt",
        matched_party: party,
        matched_tenancy: tenancy,
        payment_method: "zelle",
        payer_name: "Mystery Payer",
        amount_cents: 50_000,
        occurred_on: Date.new(2026, 8, 22)
      )

      visit inbox_path
      expect(page).to have_css("#review_form_#{invalid_txn.id}")

      # Enter invalid reference exceeding maximum length
      fill_in "rev-ref-#{invalid_txn.id}", with: "A" * 300

      # Submit confirmation
      click_button "Confirm receipt"

      # 422 error alert rendered into frame
      expect(page).to have_css("#form_error_alert")
      expect(page).to have_content("External reference is too long")

      # Verify focus shifted to error alert / invalid field, NOT confirm button
      active_id = page.evaluate_script("document.activeElement ? (document.activeElement.id || document.activeElement.tagName) : null")
      expect([ "form_error_alert", "rev-ref-#{invalid_txn.id}", "INPUT", "DIV" ]).to include(active_id)
    end
  end

  describe "narrow-screen standalone review flow", js: true do
    it "navigates to standalone review, allows editing unresolved item, and redirects through the review queue until caught up" do
      page.current_window.resize_to(375, 667)

      txn1 = create(
        :imported_transaction,
        user: user,
        source_document: source_document,
        status: "unmatched",
        transaction_kind: "unknown",
        amount_cents: 240_000,
        occurred_on: Date.new(2026, 8, 21)
      )

      txn2 = create(
        :imported_transaction,
        user: user,
        source_document: source_document,
        status: "matched",
        transaction_kind: "tenant_receipt",
        matched_party: party,
        matched_tenancy: tenancy,
        amount_cents: 120_000,
        occurred_on: Date.new(2026, 8, 20),
        payment_method: "zelle",
        external_reference: "ZL-202"
      )

      visit inbox_path
      expect(page).to have_css("#imported_transaction_#{txn2.id}")
      expect(page.evaluate_script("window.matchMedia('(min-width: 1024px)').matches")).to be(false)

      # Click the first row in queue
      page.execute_script("document.querySelector('#imported_transaction_#{txn2.id}').click()")

      # Arrive at standalone review page
      expect(page).to have_current_path(imported_transaction_path(txn2))
      expect(page).to have_content("Item 1 of 2 needing review")
      expect(page).to have_content("$1,200.00")

      # Submit confirm for txn2
      page.execute_script("document.querySelector('#review_form_#{txn2.id}').requestSubmit()")

      # 303 redirect to next reviewable transaction (txn1)
      expect(page).to have_content("Item 1 of 1 needing review")
      expect(page).to have_current_path(imported_transaction_path(txn1))
      expect(page).to have_content("$2,400.00")

      # Fill in classification and fields on standalone page and confirm
      select "Tenant receipt", from: "rev-kind-#{txn1.id}"
      select "Homer Simpson", from: "rev-party-#{txn1.id}"
      select "742 Evergreen Terrace — Main", from: "rev-tenancy-#{txn1.id}"
      page.execute_script("document.querySelector('#rev-method-#{txn1.id}').value = 'zelle'")
      page.execute_script("document.querySelector('#rev-ref-#{txn1.id}').value = 'ZL-999'")

      # Submit confirm for txn1
      page.execute_script("document.querySelector('#review_form_#{txn1.id}').requestSubmit(document.querySelector('#confirm_btn_#{txn1.id}'))")

      # 303 redirect to /inbox in caught-up state
      expect(page).to have_content("You’re caught up")
      expect(page).to have_current_path(inbox_path)

      txn1.reload
      expect(txn1.status).to eq("confirmed")
      expect(txn1.payment_method).to eq("zelle")
      expect(txn1.external_reference).to eq("ZL-999")
    end
  end

  describe "State-aware caught-up view" do
    it "displays failed import notice when queue is empty but failed documents exist" do
      create(:source_document, user: user, status: "failed", error_message: "Unreadable format")

      visit inbox_path

      expect(page).to have_content("Import Failed")
      expect(page).to have_content("1 statement upload failed processing and requires attention.")
      expect(page).to have_link("View failed uploads", href: inbox_path(view: "processing"))
    end

    it "displays processing notice when queue is empty but documents are in-flight" do
      create(:source_document, user: user, status: "processing")

      visit inbox_path

      expect(page).to have_content("Processing Statements")
      expect(page).to have_content("1 statement upload is currently processing in the background.")
      expect(page).to have_link("View processing status", href: inbox_path(view: "processing"))
    end
  end

  describe "Processing & failed tab" do
    it "displays failed and in-flight processing documents and supports retrying" do
      failed_doc = create(:source_document, user: user, status: "failed", error_message: "Multi-page statement PDFs are not supported", attachment_filename: "chase_aug.pdf")
      create(:source_document, user: user, status: "processing", attachment_filename: "venmo_aug.pdf")

      visit inbox_path(view: "processing")

      expect(page).to have_content("chase_aug.pdf")
      expect(page).to have_content("Multi-page statement PDFs are not supported")
      expect(page).to have_content("venmo_aug.pdf")
      expect(page).to have_content("Processing…")

      click_button "Retry"

      expect(page).to have_content("Document processing has been re-queued in the background.")
      expect(failed_doc.reload.status).to eq("processing")
    end
  end

  describe "Background broadcast updates", js: true do
    it "removes the document row on processing success, updates badges, and preserves active tab" do
      processing_doc = create(:source_document, user: user, status: "processing", attachment_filename: "live_success.pdf")

      visit inbox_path(view: "processing")
      expect(page).to have_content("live_success.pdf")
      expect(page).to have_content("Processing…")
      expect(page).to have_css("#inbox_tab_processing[aria-current='page']")

      # Simulate background job completing successfully
      processing_doc.update!(status: "success")
      ImportedTransactions::InboxBroadcastService.call(user: user, document: processing_doc)

      # Document row is removed from Processing tab in real time
      expect(page).to have_no_css("#source_document_#{processing_doc.id}")
      expect(page).to have_content("No uploads in flight and no failures.")

      # Active tab remains Processing & failed (does NOT switch to Needs review)
      expect(page).to have_css("#inbox_tab_processing[aria-current='page']")
      expect(page).to have_no_css("#inbox_tab_review[aria-current='page']")

      # Persisted state on reload is identical
      page.refresh
      expect(page).to have_content("No uploads in flight and no failures.")
      expect(page).to have_no_css("#source_document_#{processing_doc.id}")
      expect(page).to have_css("#inbox_tab_processing[aria-current='page']")
    end

    it "updates the default inbox view live when background ingestion finishes from caught up state" do
      processing_doc = create(:source_document, user: user, status: "processing", attachment_filename: "chase_batch.pdf")

      visit inbox_path
      # Initial state: caught up view with processing notice
      expect(page).to have_content("Processing Statements")
      expect(page).to have_content("1 statement upload is currently processing in the background.")

      # Simulate background ingestion creating 1 reviewable item and marking doc success
      new_txn = create(
        :imported_transaction,
        user: user,
        source_document: processing_doc,
        status: "matched",
        transaction_kind: "tenant_receipt",
        matched_party: party,
        matched_tenancy: tenancy,
        payer_name: "Homer Simpson",
        amount_cents: 125_000,
        occurred_on: Date.new(2026, 8, 23),
        payment_method: "zelle"
      )
      processing_doc.update!(status: "success")
      ImportedTransactions::InboxBroadcastService.call(user: user, document: processing_doc)

      # The live view replaces 'Processing Statements' with the review list and detail pane
      expect(page).to have_no_content("Processing Statements")
      expect(page).to have_css("#inbox_review")
      within("#inbox_review") do
        expect(page).to have_content("$1,250.00")
      end
      expect(page).to have_css("#sidebar_inbox_badge", text: "1")

      # Finding 1 Fix: The newly created queue row is selected with aria-current and structural indicator
      expect(page).to have_css("#imported_transaction_#{new_txn.id}[aria-current='true']")
      expect(page).to have_css("#imported_transaction_#{new_txn.id}.border-stone-900.bg-stone-100")
    end

    it "renders explicit classification warning or category in queue row status lines and formats Chase source descriptions" do
      page.current_window.resize_to(1280, 800)

      # 1. Chase statement parsed row (payer_username is nil, raw_text contains description)
      chase_txn = create(
        :imported_transaction,
        user: user,
        source_document: source_document,
        status: "matched",
        transaction_kind: "tenant_receipt",
        matched_party: party,
        matched_tenancy: tenancy,
        payer_name: "Homer Simpson",
        payer_username: nil,
        raw_text: "HSIMPSON RENT AUG",
        amount_cents: 150_000,
        occurred_on: Date.new(2026, 8, 17),
        payment_method: "zelle"
      )

      # 2. Matched but unclassified transaction
      unclassified_matched = create(
        :imported_transaction,
        user: user,
        source_document: source_document,
        status: "matched",
        transaction_kind: "unknown",
        matched_party: party,
        matched_tenancy: tenancy,
        amount_cents: 110_000,
        occurred_on: Date.new(2026, 8, 18)
      )

      # 3. Security deposit transaction
      unit2 = create(:rentable_unit, property: property, unit_identifier: "Unit 2")
      deposit_tenancy = create(:tenancy, rentable_unit: unit2, agreement_type: "fixed_term", commencement_date: Date.new(2025, 1, 1), termination_date: Date.new(2026, 12, 31))
      create(:tenancy_party, tenancy: deposit_tenancy, party: party, role: "tenant")
      create(:security_deposit, tenancy: deposit_tenancy, required_amount_cents: 200_000)

      deposit_txn = create(
        :imported_transaction,
        user: user,
        source_document: source_document,
        status: "matched",
        transaction_kind: "security_deposit",
        matched_party: party,
        matched_tenancy: deposit_tenancy,
        amount_cents: 200_000,
        occurred_on: Date.new(2026, 8, 19)
      )

      # 4. Unmatched tenant receipt
      unmatched_receipt = create(
        :imported_transaction,
        user: user,
        source_document: source_document,
        status: "unmatched",
        transaction_kind: "tenant_receipt",
        payer_name: "Unknown Person",
        amount_cents: 80_000,
        occurred_on: Date.new(2026, 8, 20)
      )

      visit inbox_path

      # Chase row shows statement description from raw_text
      within("#imported_transaction_#{chase_txn.id}") do
        expect(page).to have_content("Zelle · “HSIMPSON RENT AUG”")
        expect(page).to have_css(".yn-dot-ok")
        expect(page).to have_content("Tenant receipt · Matched · 742 Evergreen Terrace")
      end

      # Row for matched but unclassified transaction warns "Needs classification"
      within("#imported_transaction_#{unclassified_matched.id}") do
        expect(page).to have_css(".yn-dot-warn")
        expect(page).to have_content("Needs classification · 742 Evergreen Terrace")
      end

      # Row for security deposit transaction displays "Security deposit · Matched"
      within("#imported_transaction_#{deposit_txn.id}") do
        expect(page).to have_css(".yn-dot-ok")
        expect(page).to have_content("Security deposit · Matched · 742 Evergreen Terrace")
      end

      # Row for unmatched tenant receipt displays "Tenant receipt · Unmatched payer"
      within("#imported_transaction_#{unmatched_receipt.id}") do
        expect(page).to have_css(".yn-dot-warn")
        expect(page).to have_content("Tenant receipt · Unmatched payer")
      end
    end

    it "does not discard an in-progress review form when background broadcast arrives, adds new items to queue, and transitions cleanly on confirm" do
      page.current_window.resize_to(1280, 800)

      txn1 = create(
        :imported_transaction,
        user: user,
        source_document: source_document,
        status: "matched",
        transaction_kind: "tenant_receipt",
        matched_party: party,
        matched_tenancy: tenancy,
        amount_cents: 100_000,
        occurred_on: Date.new(2026, 8, 20),
        payment_method: "zelle"
      )

      processing_doc = create(:source_document, user: user, status: "processing", attachment_filename: "second_doc.pdf")

      visit inbox_path
      expect(page).to have_css("#review_form_#{txn1.id}")
      expect(page).to have_css("#imported_transaction_#{txn1.id}[aria-current='true']")

      # User makes in-progress edits in the active form
      fill_in "Reference", with: "UNSAVED-DRAFT-REF"

      # Simulate another statement finishing in the background (Item B)
      txn2 = create(
        :imported_transaction,
        user: user,
        source_document: processing_doc,
        status: "matched",
        transaction_kind: "tenant_receipt",
        matched_party: party,
        matched_tenancy: tenancy,
        amount_cents: 50_000,
        occurred_on: Date.new(2026, 8, 21),
        payment_method: "zelle"
      )
      processing_doc.update!(status: "success")
      ImportedTransactions::InboxBroadcastService.call(user: user, document: processing_doc)

      # Badges update to reflect new total items (2)
      expect(page).to have_css("#sidebar_inbox_badge", text: "2")

      # txn1 form and user's unsaved edits remain completely intact, and active reviewer queue is untouched
      expect(page).to have_css("#review_form_#{txn1.id}")
      expect(find_field("Reference").value).to eq("UNSAVED-DRAFT-REF")
      expect(page).to have_css("#imported_transaction_#{txn1.id}[aria-current='true']")

      # User confirms Item A (txn1)
      page.execute_script("document.querySelector('#review_form_#{txn1.id}').requestSubmit(document.querySelector('#confirm_btn_#{txn1.id}'))")

      # Item A is removed from the queue, newly arrived Item B (txn2) is cleanly rendered and selected
      expect(page).to have_content("Transaction confirmed and recorded successfully.")
      expect(page).to have_no_css("#imported_transaction_#{txn1.id}")
      expect(page).to have_css("#sidebar_inbox_badge", text: "1")

      # Queue row for Item B is marked selected with structural styling, and detail pane displays Item B
      expect(page).to have_css("#imported_transaction_#{txn2.id}[aria-current='true']")
      expect(page).to have_css("#imported_transaction_#{txn2.id}.border-stone-900.bg-stone-100")
      within("#inbox_review") do
        expect(page).to have_content("$500.00")
        expect(page).to have_css("#review_form_#{txn2.id}")
      end
    end

    it "updates the document row to failed in real time when processing fails" do
      processing_doc = create(:source_document, user: user, status: "processing", attachment_filename: "live_upload.pdf")

      visit inbox_path(view: "processing")
      expect(page).to have_content("live_upload.pdf")
      expect(page).to have_content("Processing…")

      # Simulate background job finishing with failure
      processing_doc.update!(status: "failed", error_message: "Unreadable format")
      ImportedTransactions::InboxBroadcastService.call(user: user, document: processing_doc)

      # Page updates automatically via Turbo Streams
      expect(page).to have_content("Failed")
      expect(page).to have_content("Unreadable format")
      expect(page).to have_button("Retry")
    end

    it "updates the default Needs review empty state in real time when processing fails and when retried" do
      processing_doc = create(:source_document, user: user, status: "processing", attachment_filename: "live_upload.pdf")

      visit inbox_path
      expect(page).to have_content("Processing Statements")

      # Simulate background job failing
      processing_doc.update!(status: "failed", error_message: "Corrupted statement")
      ImportedTransactions::InboxBroadcastService.call(user: user, document: processing_doc)

      # Empty state dynamically updates to Import Failed
      expect(page).to have_content("Import Failed")
      expect(page).to have_no_content("Processing Statements")

      # Simulate retry from failed back to processing
      processing_doc.update!(status: "processing", error_message: nil)
      ImportedTransactions::InboxBroadcastService.call(user: user, document: processing_doc)

      # Empty state dynamically updates back to Processing Statements
      expect(page).to have_content("Processing Statements")
      expect(page).to have_no_content("Import Failed")
    end

    it "retains /inbox?view=processing and Processing tab selection when clicking Retry or Delete on a document" do
      failed_doc = create(:source_document, user: user, status: "failed", error_message: "Unreadable format", attachment_filename: "bad_upload.pdf")
      delete_doc = create(:source_document, user: user, status: "failed", error_message: "Corrupted PDF", attachment_filename: "corrupt.pdf")

      visit inbox_path(view: "processing")
      expect(page).to have_content("bad_upload.pdf")
      expect(page).to have_content("corrupt.pdf")
      expect(page).to have_css("a[aria-current='page']", text: "Processing & failed")

      # Click Retry on bad_upload.pdf
      within("#source_document_#{failed_doc.id}") do
        click_button "Retry"
      end

      # URL remains /inbox?view=processing and Processing tab remains active
      expect(page).to have_current_path(inbox_path(view: "processing"))
      expect(page).to have_content("Document processing has been re-queued in the background.")
      expect(page).to have_css("a[aria-current='page']", text: "Processing & failed")

      # Click Delete… on corrupt.pdf
      within("#source_document_#{delete_doc.id}") do
        click_button "Delete…"
      end

      # Confirm deletion in turbo-confirm modal
      within("#confirm-modal") do
        expect(page).to have_content("Are you sure you want to delete this upload record?")
        click_button "Confirm"
      end

      # URL remains /inbox?view=processing and Processing tab remains active
      expect(page).to have_current_path(inbox_path(view: "processing"))
      expect(page).to have_content("Upload record was removed.")
      expect(page).to have_css("a[aria-current='page']", text: "Processing & failed")
      expect(page).to have_no_css("#source_document_#{delete_doc.id}")
    end

    it "bootstraps the review workspace correctly when multiple documents complete concurrently" do
      doc1 = create(:source_document, user: user, status: "processing", attachment_filename: "doc1.pdf")
      doc2 = create(:source_document, user: user, status: "processing", attachment_filename: "doc2.pdf")

      visit inbox_path
      expect(page).to have_content("Processing Statements")

      # Both background jobs finish and persist reviewable transactions before either broadcast runs
      txn1 = create(
        :imported_transaction,
        user: user,
        source_document: doc1,
        status: "matched",
        transaction_kind: "tenant_receipt",
        matched_party: party,
        matched_tenancy: tenancy,
        payer_name: "Alice Walker",
        amount_cents: 100_000,
        occurred_on: Date.new(2026, 8, 20),
        payment_method: "zelle"
      )
      doc1.update!(status: "success")

      txn2 = create(
        :imported_transaction,
        user: user,
        source_document: doc2,
        status: "matched",
        transaction_kind: "tenant_receipt",
        matched_party: party,
        matched_tenancy: tenancy,
        payer_name: "Bob Builder",
        amount_cents: 150_000,
        occurred_on: Date.new(2026, 8, 21),
        payment_method: "zelle"
      )
      doc2.update!(status: "success")

      # Concurrent broadcasts execute
      ImportedTransactions::InboxBroadcastService.call(user: user, document: doc1)
      ImportedTransactions::InboxBroadcastService.call(user: user, document: doc2)

      # Review workspace is bootstrapped and both items are present
      expect(page).to have_no_content("Processing Statements")
      expect(page).to have_css("#imported_transaction_#{txn1.id}")
      expect(page).to have_css("#imported_transaction_#{txn2.id}")
      expect(page).to have_css("#sidebar_inbox_badge", text: "2")

      # Selected row remains clearly identifiable after multiple broadcasts
      expect(page).to have_css("#imported_transaction_#{txn2.id}[aria-current='true']")
      expect(page).to have_css("#imported_transaction_#{txn2.id}.border-stone-900.bg-stone-100")
      expect(page).to have_no_css("#imported_transaction_#{txn1.id}[aria-current='true']")

      # User confirms the first selected transaction (txn2)
      page.execute_script("document.querySelector('#review_form_#{txn2.id}').requestSubmit(document.querySelector('#confirm_btn_#{txn2.id}'))")

      # Transaction confirmed, queue list updates, and next transaction (txn1) is selected
      expect(page).to have_content("Transaction confirmed and recorded successfully.")
      expect(page).to have_no_css("#imported_transaction_#{txn2.id}")
      expect(page).to have_css("#imported_transaction_#{txn1.id}[aria-current='true']")
      expect(page).to have_css("#imported_transaction_#{txn1.id}.border-stone-900.bg-stone-100")
      within("#inbox_review") do
        expect(page).to have_content("$1,000.00")
        expect(page).to have_css("#review_form_#{txn1.id}")
      end
    end

    it "removes deleted document rows and cascaded unconfirmed transactions in real time across open sessions" do
      failed_doc = create(:source_document, user: user, status: "failed", error_message: "Invalid encoding", attachment_filename: "corrupt.pdf")
      unconfirmed_txn = create(
        :imported_transaction,
        user: user,
        source_document: failed_doc,
        status: "unmatched",
        amount_cents: 80_000,
        occurred_on: Date.new(2026, 8, 22)
      )

      # Session 1: On Processing tab
      visit inbox_path(view: "processing")
      expect(page).to have_css("#source_document_#{failed_doc.id}")

      # Session 2: Deletes the failed document via service
      SourceDocuments::DestroyService.call(user: user, document: failed_doc)

      # Session 1 receives real-time broadcast removal
      expect(page).to have_no_css("#source_document_#{failed_doc.id}")
      expect(page).to have_content("No uploads in flight and no failures.")
    end

    it "automatically selects the next transaction or transitions to caught-up when the actively reviewed item is destroyed remotely" do
      doc1 = create(:source_document, user: user, status: "success", attachment_filename: "doc1.pdf")
      doc2 = create(:source_document, user: user, status: "success", attachment_filename: "doc2.pdf")

      txn1 = create(
        :imported_transaction,
        user: user,
        source_document: doc1,
        status: "matched",
        transaction_kind: "tenant_receipt",
        matched_party: party,
        matched_tenancy: tenancy,
        amount_cents: 100_000,
        occurred_on: Date.new(2026, 8, 20),
        payment_method: "zelle"
      )

      txn2 = create(
        :imported_transaction,
        user: user,
        source_document: doc2,
        status: "matched",
        transaction_kind: "tenant_receipt",
        matched_party: party,
        matched_tenancy: tenancy,
        amount_cents: 50_000,
        occurred_on: Date.new(2026, 8, 21),
        payment_method: "zelle"
      )

      visit inbox_path
      # txn2 is first in queue (newer date/created_at) and selected
      expect(page).to have_css("#imported_transaction_#{txn2.id}[aria-current='true']")
      expect(page).to have_css("#review_form_#{txn2.id}")

      # Another tab deletes doc2 (which cascades txn2)
      SourceDocuments::DestroyService.call(user: user, document: doc2)

      # Tab 1 automatically observes removal and selects the next available item (txn1)
      expect(page).to have_no_css("#imported_transaction_#{txn2.id}")
      expect(page).to have_css("#imported_transaction_#{txn1.id}[aria-current='true']")
      within("#inbox_review") do
        expect(page).to have_content("$1,000.00")
        expect(page).to have_css("#review_form_#{txn1.id}")
      end

      # Now another tab deletes doc1 (which cascades the last remaining item txn1)
      SourceDocuments::DestroyService.call(user: user, document: doc1)

      # Tab 1 transitions cleanly to caught-up without throwing RecordNotFound
      expect(page).to have_content("You’re caught up")
      expect(page).to have_no_css("#inbox_review_workspace")
    end

    it "reconciles and surfaces background review items if a stale confirm response arrives after newer ingestion" do
      doc1 = create(:source_document, user: user, status: "success", attachment_filename: "doc1.pdf")
      txn1 = create(
        :imported_transaction,
        user: user,
        source_document: doc1,
        status: "matched",
        transaction_kind: "tenant_receipt",
        matched_party: party,
        matched_tenancy: tenancy,
        amount_cents: 100_000,
        occurred_on: Date.new(2026, 8, 20),
        payment_method: "zelle"
      )

      visit inbox_path
      expect(page).to have_css("#review_form_#{txn1.id}")

      # Ingest a new document B in background and broadcast with a newer revision
      doc2 = create(:source_document, user: user, status: "success", attachment_filename: "doc2.pdf")
      txn2 = create(
        :imported_transaction,
        user: user,
        source_document: doc2,
        status: "matched",
        transaction_kind: "tenant_receipt",
        matched_party: party,
        matched_tenancy: tenancy,
        amount_cents: 200_000,
        occurred_on: Date.new(2026, 8, 22),
        payment_method: "zelle"
      )

      # Simulate background ingestion B committing and broadcasting (incrementing user.inbox_revision to newer_revision)
      user.increment_inbox_revision!
      newer_revision = user.reload.inbox_revision

      Turbo::StreamsChannel.broadcast_replace_to(
        [ user, :inbox ],
        target: "inbox_sync",
        partial: "imported_transactions/sync_target",
        locals: { revision: newer_revision, review_count: 2 }
      )
      Turbo::StreamsChannel.broadcast_replace_to(
        [ user, :inbox ],
        target: "sidebar_inbox_badge",
        partial: "shared/inbox_badge",
        locals: { count: 2, id: "sidebar_inbox_badge", target_id: "sidebar_inbox_badge" }
      )

      # Wait for Action Cable broadcast to arrive and advance maxRevision
      expect(page).to have_css("#sidebar_inbox_badge", text: "2")

      # Client now has maxRevision = newer_revision
      # Now simulate a stale HTTP response arriving with an older revision (0) and count 0
      stale_stream = %(
        <turbo-stream action="replace" target="inbox_review_workspace">
          <template>
            <div id="inbox_review_empty"><div id="inbox_caught_up"><p>You’re caught up</p></div></div>
          </template>
        </turbo-stream>
        <turbo-stream action="replace" target="inbox_sync">
          <template>
            <div id="inbox_sync" class="hidden" data-controller="inbox-sync" data-inbox-sync-revision-value="0" data-inbox-sync-review-count-value="0"></div>
          </template>
        </turbo-stream>
      )

      # Inject stale stream into page
      page.execute_script("Turbo.renderStreamMessage(arguments[0])", stale_stream)

      # inbox-sync detects stale revision (0 < newer_revision) and automatically refreshes to canonical state
      expect(page).to have_css("#imported_transaction_#{txn2.id}")
      expect(page).to have_no_content("You’re caught up")
    end

    it "does not steal keyboard focus during background Action Cable broadcasts" do
      processing_doc = create(:source_document, user: user, status: "processing", attachment_filename: "bg_job.pdf")

      visit inbox_path
      expect(page).to have_content("Processing Statements")

      # User focuses on a header link
      find("a", text: "Portfolio").native.send_keys(:tab)
      focused_before = page.evaluate_script("document.activeElement.tagName")

      # Background job fails and broadcasts
      processing_doc.update!(status: "failed", error_message: "Format error")
      ImportedTransactions::InboxBroadcastService.call(user: user, document: processing_doc)

      # Empty state updates live
      expect(page).to have_content("Import Failed")

      # Focus was not stolen by the background broadcast
      focused_after = page.evaluate_script("document.activeElement.id")
      expect(focused_after).not_to eq("inbox_caught_up_title")
      expect(focused_after).not_to eq("inbox_caught_up")
    end

    it "displays a newly uploaded processing document in an already-open Processing tab before completion" do
      visit inbox_path(view: "processing")
      expect(page).to have_content("No uploads in flight and no failures.")

      # Another session uploads a PDF
      new_doc = create(:source_document, user: user, status: "processing", attachment_filename: "statement_aug.pdf")
      user.increment_inbox_revision!
      ImportedTransactions::InboxBroadcastService.call(user: user, document: new_doc)

      # Open processing tab immediately displays the newly uploaded processing row
      expect(page).to have_content("statement_aug.pdf")
      expect(page).to have_content("Processing")
      expect(page).to have_no_content("No uploads in flight and no failures.")
    end

    it "reconciles and refreshes canonical state on the Processing tab when a stale broadcast arrives" do
      doc = create(:source_document, user: user, status: "processing", attachment_filename: "doc_proc.pdf")
      visit inbox_path(view: "processing")
      expect(page).to have_content("doc_proc.pdf")

      # Advance user revision
      user.increment_inbox_revision!
      newer_revision = user.reload.inbox_revision

      # Broadcast newer revision sync
      Turbo::StreamsChannel.broadcast_replace_to(
        [ user, :inbox ],
        target: "inbox_sync",
        partial: "imported_transactions/sync_target",
        locals: { revision: newer_revision, review_count: 0 }
      )

      # Document finishes in database
      doc.update!(status: "failed", error_message: "Format parse error")

      # Simulate stale broadcast arriving with older revision (0)
      stale_stream = %(
        <turbo-stream action="replace" target="inbox_sync">
          <template>
            <div id="inbox_sync" class="hidden" data-controller="inbox-sync" data-inbox-sync-revision-value="0" data-inbox-sync-review-count-value="0"></div>
          </template>
        </turbo-stream>
      )
      page.execute_script("Turbo.renderStreamMessage(arguments[0])", stale_stream)

      # inbox-sync detects 0 < newer_revision and reloads /inbox?view=processing to canonical state
      expect(page).to have_content("Format parse error")
      expect(page).to have_content("Retry")
    end

    it "reconciles and surfaces canonical state when a stale update response arrives after newer remote confirm/deletion" do
      doc1 = create(:source_document, user: user, status: "success", attachment_filename: "doc1.pdf")
      txn1 = create(
        :imported_transaction,
        user: user,
        source_document: doc1,
        status: "matched",
        transaction_kind: "tenant_receipt",
        matched_party: party,
        matched_tenancy: tenancy,
        amount_cents: 100_000,
        occurred_on: Date.new(2026, 8, 20),
        payment_method: "zelle"
      )

      visit inbox_path
      expect(page).to have_css("#review_form_#{txn1.id}")

      # Another tab deletes doc1 (which cascades txn1 in DB, increments revision, and broadcasts caught-up)
      SourceDocuments::DestroyService.call(user: user, document: doc1)
      expect(ImportedTransaction.exists?(txn1.id)).to be(false)
      expect(page).to have_content("You’re caught up")
      expect(page).to have_no_css("#sidebar_inbox_badge .yn-count")

      # Now simulate an older Save (Update) HTTP response arriving carrying an older revision (0)
      # which renders a stale badge count (1) followed by an older inbox_sync marker (0)
      stale_update_stream = %(
        <turbo-stream action="replace" target="sidebar_inbox_badge">
          <template>
            <span id="sidebar_inbox_badge"><span class="yn-count">1</span></span>
          </template>
        </turbo-stream>
        <turbo-stream action="replace" target="inbox_sync">
          <template>
            <div id="inbox_sync" class="hidden" data-controller="inbox-sync" data-inbox-sync-revision-value="0" data-inbox-sync-review-count-value="1"></div>
          </template>
        </turbo-stream>
      )
      page.execute_script("Turbo.renderStreamMessage(arguments[0])", stale_update_stream)

      # inbox-sync detects stale revision (0 < observed max revision) and automatically refreshes to canonical DB state (caught up, no badge count)
      expect(page).to have_no_css("#sidebar_inbox_badge .yn-count")
      expect(page).to have_content("You’re caught up")
      expect(page).to have_no_css("#imported_transaction_#{txn1.id}")
      expect(page).to have_no_css("#inbox_review_workspace")
    end

    it "reconciles and reloads the canonical queue when background work arrives and the only visible row is removed remotely" do
      doc1 = create(:source_document, user: user, status: "success", attachment_filename: "doc1.pdf")
      txn1 = create(
        :imported_transaction,
        user: user,
        source_document: doc1,
        status: "matched",
        transaction_kind: "tenant_receipt",
        matched_party: party,
        matched_tenancy: tenancy,
        amount_cents: 100_000,
        occurred_on: Date.new(2026, 8, 20),
        payment_method: "zelle"
      )

      # User loads Inbox with only txn1 in the workspace
      visit inbox_path
      expect(page).to have_css("#imported_transaction_#{txn1.id}[aria-current='true']")

      # Background ingestion creates txn2 without replacing the existing active workspace
      doc2 = create(:source_document, user: user, status: "success", attachment_filename: "doc2.pdf")
      txn2 = create(
        :imported_transaction,
        user: user,
        source_document: doc2,
        status: "matched",
        transaction_kind: "tenant_receipt",
        matched_party: party,
        matched_tenancy: tenancy,
        amount_cents: 200_000,
        occurred_on: Date.new(2026, 8, 22),
        payment_method: "zelle"
      )
      ImportedTransactions::InboxBroadcastService.call(user: user, document: doc2)

      # Tab 1 badge becomes 2, while queue list still has only txn1
      expect(page).to have_css("#sidebar_inbox_badge", text: "2")
      expect(page).to have_css("#imported_transaction_#{txn1.id}")
      expect(page).to have_no_css("#imported_transaction_#{txn2.id}")

      # Another tab deletes doc1 (which removes txn1 remotely)
      SourceDocuments::DestroyService.call(user: user, document: doc1)

      # Tab 1 observes 0 remaining visible rows, automatically reloads canonical inbox, and surfaces txn2!
      expect(page).to have_no_css("#imported_transaction_#{txn1.id}")
      expect(page).to have_css("#imported_transaction_#{txn2.id}[aria-current='true']")
      within("#inbox_review") do
        expect(page).to have_content("$2,000.00")
        expect(page).to have_css("#review_form_#{txn2.id}")
      end
    end

    it "guards against write conflicts when a stale review form attempts to confirm a record modified elsewhere" do
      party_bob = create(:party, user: user, display_name: "Bob Tenant")
      doc = create(:source_document, user: user, status: "success", attachment_filename: "doc.pdf")
      txn = create(
        :imported_transaction,
        user: user,
        source_document: doc,
        status: "matched",
        transaction_kind: "tenant_receipt",
        matched_party: party,
        matched_tenancy: tenancy,
        amount_cents: 100_000,
        occurred_on: Date.new(2026, 8, 20),
        payment_method: "zelle"
      )

      # Tab A visits inbox with matched_party = Alice (party) and lock_version = 0
      visit inbox_path
      expect(page).to have_css("#review_form_#{txn.id}")
      expect(page).to have_select("Payer", selected: party.display_name)

      # Tab A types an in-progress draft into the Reference field
      fill_in "Reference", with: "Draft Ref 999"

      # In another tab/session (Tab B), user saves changes (e.g. changes payer to Bob and amount to $1,500)
      update_res = ImportedTransactions::UpdateService.call(
        user: user,
        transaction: txn,
        params: { matched_party_id: party_bob.id, amount: "1500.00", lock_version: txn.lock_version }
      )
      expect(update_res).to be_success
      expect(txn.reload.matched_party).to eq(party_bob)
      expect(txn.reload.amount_cents).to eq(150_000)
      expect(txn.lock_version).to eq(1)

      # The queue row summary visibly reflects the remote save ($1,500.00) via Action Cable
      expect(page).to have_css("#imported_transaction_#{txn.id}", text: "$1,500.00")

      # Tab A's active selection and unsaved draft form are preserved without reload
      expect(page).to have_css("#imported_transaction_#{txn.id}[aria-current='true']")
      expect(find_field("Reference").value).to eq("Draft Ref 999")

      # Tab A now tries to confirm using its stale form (which has lock_version = 0 and stale payer Alice)
      click_button "Confirm receipt"

      # Tab A receives 422 conflict alert and the database retains Tab B's Bob update
      expect(page).to have_content("This transaction was updated in another session. Please reload to review the latest changes.")
      expect(txn.reload.matched_party).to eq(party_bob)
      expect(txn.reload.amount_cents).to eq(150_000)
      expect(txn.reload.status).to eq("matched")
      expect(Receipt.count).to eq(0)
    end

    it "guards against write conflicts when a stale review form attempts to delete a record modified elsewhere" do
      party_bob = create(:party, user: user, display_name: "Bob Tenant")
      doc = create(:source_document, user: user, status: "success", attachment_filename: "doc.pdf")
      txn = create(
        :imported_transaction,
        user: user,
        source_document: doc,
        status: "unmatched",
        transaction_kind: "unknown",
        matched_party: party,
        matched_tenancy: nil,
        amount_cents: 100_000,
        occurred_on: Date.new(2026, 8, 20),
        payment_method: "zelle"
      )

      # Tab A visits inbox with transaction at lock_version = 0
      visit inbox_path
      expect(page).to have_css("#review_form_#{txn.id}")

      # In another tab/session (Tab B), user saves changes (updating amount to $1,500 and party to Bob)
      update_res = ImportedTransactions::UpdateService.call(
        user: user,
        transaction: txn,
        params: { matched_party_id: party_bob.id, amount: "1500.00", lock_version: txn.lock_version }
      )
      expect(update_res).to be_success
      expect(txn.reload.matched_party).to eq(party_bob)
      expect(txn.reload.amount_cents).to eq(150_000)
      expect(txn.lock_version).to eq(1)

      # The queue row summary visibly reflects the remote save ($1,500.00) via Action Cable
      expect(page).to have_css("#imported_transaction_#{txn.id}", text: "$1,500.00")

      # Tab A clicks Delete on its stale form (lock_version = 0)
      click_button "Delete…"
      within("#confirm-modal") do
        expect(page).to have_content("Are you sure you want to delete this imported transaction?")
        click_button "Confirm"
      end

      # Tab A receives 422 conflict alert and the database retains Tab B's updated transaction
      expect(page).to have_content("This transaction was updated in another session. Please reload to review the latest changes.")
      expect(ImportedTransaction.exists?(txn.id)).to be(true)
      expect(txn.reload.matched_party).to eq(party_bob)
      expect(txn.reload.amount_cents).to eq(150_000)
    end

    it "smoothly transitions workspace when a local save races with remote document deletion" do
      doc = create(:source_document, user: user, status: "success", attachment_filename: "doc.pdf")
      txn2 = create(
        :imported_transaction,
        user: user,
        source_document: doc,
        status: "unmatched",
        amount_cents: 200_000,
        occurred_on: Date.new(2026, 8, 21),
        payment_method: "zelle"
      )
      txn1 = create(
        :imported_transaction,
        user: user,
        source_document: doc,
        status: "unmatched",
        amount_cents: 100_000,
        occurred_on: Date.new(2026, 8, 20),
        payment_method: "zelle"
      )

      visit inbox_path
      expect(page).to have_css("#review_form_#{txn1.id}")

      original_call = ImportedTransactions::UpdateService.method(:call)
      allow(ImportedTransactions::UpdateService).to receive(:call) do |user:, transaction:, params:|
        res = original_call.call(user: user, transaction: transaction, params: params)
        transaction.destroy!
        user.increment_inbox_revision!
        res
      end

      click_button "Save without confirming"

      expect(page).to have_content("Transaction record updated successfully.")
      expect(page).to have_css("#review_form_#{txn2.id}")
      expect(page).not_to have_css("#imported_transaction_#{txn1.id}")
    end

    it "reconciles frame selection responses when an older GET arrives after a remote update advances revision" do
      doc = create(:source_document, user: user, status: "success", attachment_filename: "doc.pdf")
      txn2 = create(
        :imported_transaction,
        user: user,
        source_document: doc,
        status: "unmatched",
        amount_cents: 200_000,
        occurred_on: Date.new(2026, 8, 21),
        payment_method: "zelle"
      )
      txn1 = create(
        :imported_transaction,
        user: user,
        source_document: doc,
        status: "unmatched",
        amount_cents: 100_000,
        occurred_on: Date.new(2026, 8, 20),
        payment_method: "zelle"
      )

      visit inbox_path
      expect(page).to have_css("#review_form_#{txn1.id}")

      # When txn2 is clicked, delay its frame response while a remote Save on txn2 commits and broadcasts
      mocking = false
      original_inbox_query = ImportedTransactions::InboxQuery.method(:new)
      allow(ImportedTransactions::InboxQuery).to receive(:new) do |**args|
        query = original_inbox_query.call(**args)
        if !mocking && args[:updated_transaction_id] == txn2.id
          mocking = true
          txn2.update!(amount_cents: 250_000)
          ImportedTransactions::InboxBroadcastService.call(user: user, updated_transaction_id: txn2.id)
          mocking = false
        end
        query
      end

      find("#imported_transaction_#{txn2.id}").click

      expect(page).to have_css("#review_form_#{txn2.id}")
      expect(page).to have_content("$2,500.00")
    end

    it "smoothly reconciles frame selection when requested transaction is deleted before snapshot" do
      doc = create(:source_document, user: user, status: "success", attachment_filename: "doc.pdf")
      txn2 = create(
        :imported_transaction,
        user: user,
        source_document: doc,
        status: "unmatched",
        amount_cents: 200_000,
        occurred_on: Date.new(2026, 8, 21),
        payment_method: "zelle"
      )
      txn1 = create(
        :imported_transaction,
        user: user,
        source_document: doc,
        status: "unmatched",
        amount_cents: 100_000,
        occurred_on: Date.new(2026, 8, 20),
        payment_method: "zelle"
      )

      visit inbox_path
      expect(page).to have_css("#review_form_#{txn1.id}")

      mocking = false
      original_inbox_query = ImportedTransactions::InboxQuery.method(:new)
      allow(ImportedTransactions::InboxQuery).to receive(:new) do |**args|
        if !mocking && args[:updated_transaction_id] == txn2.id
          mocking = true
          txn2.destroy!
          user.increment_inbox_revision!
          mocking = false
        end
        original_inbox_query.call(**args)
      end

      find("#imported_transaction_#{txn2.id}").click

      expect(page).to have_css("#review_form_#{txn1.id}")
      expect(page).not_to have_css("#review_form_#{txn2.id}")
    end

    it "smoothly reconciles frame selection when requested transaction is confirmed before snapshot" do
      doc = create(:source_document, user: user, status: "success", attachment_filename: "doc.pdf")
      txn2 = create(
        :imported_transaction,
        user: user,
        source_document: doc,
        status: "unmatched",
        amount_cents: 200_000,
        occurred_on: Date.new(2026, 8, 21),
        payment_method: "zelle"
      )
      txn1 = create(
        :imported_transaction,
        user: user,
        source_document: doc,
        status: "unmatched",
        amount_cents: 100_000,
        occurred_on: Date.new(2026, 8, 20),
        payment_method: "zelle"
      )

      visit inbox_path
      expect(page).to have_css("#review_form_#{txn1.id}")

      receipt = create(:receipt, user: user, tenancy: tenancy, amount_cents: txn2.amount_cents)
      mocking = false
      original_inbox_query = ImportedTransactions::InboxQuery.method(:new)
      allow(ImportedTransactions::InboxQuery).to receive(:new) do |**args|
        if !mocking && args[:updated_transaction_id] == txn2.id
          mocking = true
          txn2.update_columns(status: "confirmed", confirmed_source_type: "Receipt", confirmed_source_id: receipt.id)
          user.increment_inbox_revision!
          mocking = false
        end
        original_inbox_query.call(**args)
      end

      find("#imported_transaction_#{txn2.id}").click

      expect(page).to have_css("#review_form_#{txn1.id}")
      expect(page).not_to have_css("#review_form_#{txn2.id}")
    end

    it "refreshes canonical workspace selecting newly arrived background transaction when reviewed row is removed remotely" do
      doc = create(:source_document, user: user, status: "success", attachment_filename: "doc.pdf")
      txn_b = create(
        :imported_transaction,
        user: user,
        source_document: doc,
        status: "unmatched",
        amount_cents: 200_000,
        occurred_on: Date.new(2026, 8, 20),
        created_at: 2.hours.ago,
        payment_method: "zelle"
      )
      txn_a = create(
        :imported_transaction,
        user: user,
        source_document: doc,
        status: "unmatched",
        amount_cents: 100_000,
        occurred_on: Date.new(2026, 8, 21),
        created_at: 1.hour.ago,
        payment_method: "zelle"
      )

      visit inbox_path
      expect(page).to have_css("#review_form_#{txn_a.id}")

      # Background ingestion creates newer transaction D
      txn_d = create(
        :imported_transaction,
        user: user,
        source_document: doc,
        status: "unmatched",
        amount_cents: 300_000,
        occurred_on: Date.new(2026, 8, 22),
        created_at: Time.current,
        payment_method: "zelle"
      )

      # Another session confirms currently reviewed txn_a and broadcasts its removal
      receipt_a = create(:receipt, user: user, tenancy: tenancy, amount_cents: txn_a.amount_cents)
      txn_a.update_columns(status: "confirmed", confirmed_source_type: "Receipt", confirmed_source_id: receipt_a.id)
      user.increment_inbox_revision!
      ImportedTransactions::InboxBroadcastService.call(user: user, deleted_transaction_ids: [ txn_a.id ])

      # reconcileQueue refreshes the canonical queue which includes txn_d and selects txn_d
      expect(page).to have_css("#review_form_#{txn_d.id}")
      expect(page).to have_css("#imported_transaction_#{txn_d.id}[aria-current='true']")
      expect(page).not_to have_css("#imported_transaction_#{txn_a.id}")
    end

    it "renders next canonical transaction when clicking a row that was deleted in DB prior to request" do
      doc = create(:source_document, user: user, status: "success", attachment_filename: "doc.pdf")
      txn2 = create(
        :imported_transaction,
        user: user,
        source_document: doc,
        status: "unmatched",
        amount_cents: 200_000,
        occurred_on: Date.new(2026, 8, 21),
        payment_method: "zelle"
      )
      txn1 = create(
        :imported_transaction,
        user: user,
        source_document: doc,
        status: "unmatched",
        amount_cents: 100_000,
        occurred_on: Date.new(2026, 8, 20),
        payment_method: "zelle"
      )

      visit inbox_path
      expect(page).to have_css("#review_form_#{txn1.id}")

      # Remote deletion occurs before client clicks
      txn2.destroy!
      user.increment_inbox_revision!

      find("#imported_transaction_#{txn2.id}").click

      # Frame receives next transaction (txn1) without 404, and queue selection is synchronized
      expect(page).to have_css("#review_form_#{txn1.id}")
      expect(page).to have_css("#imported_transaction_#{txn1.id}[aria-current='true']")
      expect(page).not_to have_css("#imported_transaction_#{txn2.id}[aria-current='true']")
      expect(page).not_to have_css("#review_form_#{txn2.id}")
    end
  end

  describe "History tab" do
    it "displays confirmed transaction records, supports filtering, pagination, and browser history navigation", js: true do
      # Create 22 Zelle transactions and 3 Check transactions (25 total)
      22.times do |i|
        create(
          :imported_transaction,
          :confirmed_receipt,
          user: user,
          source_document: source_document,
          matched_tenancy: tenancy,
          amount_cents: 100_000 + (i * 1000),
          occurred_on: Date.new(2026, 8, 1) + i.days,
          payment_method: "zelle",
          external_reference: "ZEL-#{100 + i}"
        )
      end

      3.times do |i|
        create(
          :imported_transaction,
          :confirmed_receipt,
          user: user,
          source_document: source_document,
          matched_tenancy: tenancy,
          amount_cents: 50_000 + (i * 1000),
          occurred_on: Date.new(2026, 7, 1) + i.days,
          payment_method: "check",
          external_reference: "CHK-#{100 + i}"
        )
      end

      visit inbox_path(view: "history")

      # Tab badge shows total count (25)
      expect(page).to have_css("#tab_history_count", text: "25")
      expect(page).to have_content("Showing 1–20 of 25")
      expect(page).to have_link("Next")

      # Filter by payment method Zelle
      select "Zelle", from: "payment_method"
      click_button "Filter"

      # Finding 3 / P2 Fix: Tab badge retains total count (25) while text shows filtered count (22)
      expect(page).to have_css("#tab_history_count", text: "25")
      expect(page).to have_content("Showing 1–20 of 22")
      expect(page).to have_link("Next")

      # Background broadcast arrives
      ImportedTransactions::InboxBroadcastService.call(user: user, document: nil)

      # Tab badge remains 25
      expect(page).to have_css("#tab_history_count", text: "25")

      # Navigate to Page 2
      click_link "Next"
      expect(page).to have_content("Showing 21–22 of 22")
      expect(page).to have_link("Previous")
      expect(page).to have_current_path(/page=2/)
      expect(page).to have_current_path(/view=history/)

      # Browser Back button returns to Page 1 with filter preserved
      page.go_back
      expect(page).to have_content("Showing 1–20 of 22")
      expect(find_field("payment_method").value).to eq("zelle")

      # Browser Forward button returns to Page 2 with filter preserved
      page.go_forward
      expect(page).to have_content("Showing 21–22 of 22")
      expect(find_field("payment_method").value).to eq("zelle")

      # Clear filter
      click_link "Clear"
      expect(page).to have_content("Showing 1–20 of 25")
    end
  end
end
