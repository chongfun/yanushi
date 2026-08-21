require "rails_helper"

RSpec.describe SecurityDepositTransactions::CorrectService do
  let(:user) { create(:user) }
  let(:property) { create(:property, user: user) }
  let(:unit) { create(:rentable_unit, property: property) }
  let(:tenancy) { create(:tenancy, rentable_unit: unit) }
  let(:party) { create(:party, user: user) }
  let(:party2) { create(:party, user: user) }
  let(:security_deposit) { create(:security_deposit, tenancy: tenancy, required_amount_cents: 200_000) }

  before do
    Accounting::ChartOfAccounts.ensure_for(user)
  end

  describe "correcting a received transaction" do
    it "reverses original at original date, creates replacement, links superseded_by, and updates balance" do
      res = SecurityDepositTransactions::ReceiveService.call(
        security_deposit: security_deposit,
        party: party,
        amount_cents: 100_000,
        occurred_on: Date.new(2026, 1, 1)
      )
      orig_txn = res.value!.data[:transaction]

      correct_res = described_class.call(
        transaction: orig_txn,
        amount_cents: 150_000,
        occurred_on: Date.new(2026, 1, 1)
      )

      expect(correct_res).to be_success
      replacement = correct_res.value!.data[:replacement]
      expect(replacement.amount_cents).to eq(150_000)
      expect(orig_txn.reload).to be_superseded
      expect(orig_txn.superseded_by).to eq(replacement)
      expect(security_deposit.held_cents).to eq(150_000)
    end

    it "allows clearing memo and external_reference" do
      res = SecurityDepositTransactions::ReceiveService.call(
        security_deposit: security_deposit,
        party: party,
        amount_cents: 100_000,
        occurred_on: Date.new(2026, 1, 1),
        external_reference: "CHK99",
        memo: "Initial memo"
      )
      orig_txn = res.value!.data[:transaction]

      correct_res = described_class.call(
        transaction: orig_txn,
        external_reference: "",
        memo: ""
      )

      expect(correct_res).to be_success
      rep = correct_res.value!.data[:replacement]
      expect(rep.external_reference).to be_nil
      expect(rep.memo).to be_nil
    end

    it "accepts integer amount_cents and rejects string amount_cents" do
      res = SecurityDepositTransactions::ReceiveService.call(
        security_deposit: security_deposit,
        party: party,
        amount_cents: 100_000,
        occurred_on: Date.new(2026, 1, 1)
      )
      orig_txn = res.value!.data[:transaction]

      valid_res = described_class.call(
        transaction: orig_txn,
        amount_cents: 120_000
      )
      expect(valid_res).to be_success

      invalid_res = described_class.call(
        transaction: valid_res.value!.data[:replacement],
        amount_cents: "130000"
      )
      expect(invalid_res).to be_failure
      expect(invalid_res.failure.code).to eq(:invalid_input)
    end

    it "rejects invalid party_id rather than falling back to old party" do
      res = SecurityDepositTransactions::ReceiveService.call(
        security_deposit: security_deposit,
        party: party,
        amount_cents: 100_000,
        occurred_on: Date.new(2026, 1, 1)
      )
      orig_txn = res.value!.data[:transaction]

      correct_res = described_class.call(
        transaction: orig_txn,
        party_id: 999_999
      )

      expect(correct_res).to be_failure
      expect(correct_res.failure.code).to eq(:invalid_party)
      expect(orig_txn.reload).not_to be_superseded
    end

    it "is idempotent on identical retry" do
      res = SecurityDepositTransactions::ReceiveService.call(
        security_deposit: security_deposit,
        party: party,
        amount_cents: 100_000,
        occurred_on: Date.new(2026, 1, 1)
      )
      orig_txn = res.value!.data[:transaction]

      c1 = described_class.call(transaction: orig_txn, amount_cents: 120_000)
      expect(c1).to be_success

      c2 = described_class.call(transaction: orig_txn, amount_cents: 120_000)
      expect(c2).to be_success
      expect(c2.value!.data[:replacement].id).to eq(c1.value!.data[:replacement].id)
    end

    it "returns idempotency_conflict when retried with different parameters" do
      res = SecurityDepositTransactions::ReceiveService.call(
        security_deposit: security_deposit,
        party: party,
        amount_cents: 100_000,
        occurred_on: Date.new(2026, 1, 1)
      )
      orig_txn = res.value!.data[:transaction]

      described_class.call(transaction: orig_txn, amount_cents: 120_000)
      c2 = described_class.call(transaction: orig_txn, amount_cents: 130_000)
      expect(c2).to be_failure
      expect(c2.failure.code).to eq(:idempotency_conflict)
    end

    it "rejects correction of voided transaction" do
      res = SecurityDepositTransactions::ReceiveService.call(
        security_deposit: security_deposit,
        party: party,
        amount_cents: 100_000,
        occurred_on: Date.new(2026, 1, 1)
      )
      orig_txn = res.value!.data[:transaction]
      SecurityDepositTransactions::VoidService.call(transaction: orig_txn)

      correct_res = described_class.call(transaction: orig_txn, amount_cents: 120_000)
      expect(correct_res).to be_failure
      expect(correct_res.failure.code).to eq(:already_voided)
    end
  end

  describe "correcting a refunded transaction" do
    it "replaces refund with updated amount and party" do
      SecurityDepositTransactions::ReceiveService.call(
        security_deposit: security_deposit,
        party: party,
        amount_cents: 200_000,
        occurred_on: Date.new(2026, 1, 1)
      )

      ref_res = SecurityDepositTransactions::RefundService.call(
        security_deposit: security_deposit,
        party: party,
        amount_cents: 50_000,
        occurred_on: Date.new(2026, 1, 5)
      )
      ref_txn = ref_res.value!.data[:transaction]

      correct_res = described_class.call(
        transaction: ref_txn,
        amount_cents: 80_000,
        party: party2,
        memo: "Updated refund to roommate"
      )

      expect(correct_res).to be_success
      expect(security_deposit.held_cents).to eq(120_000)
      expect(correct_res.value!.data[:replacement].party).to eq(party2)
    end
  end

  describe "correcting an applied transaction" do
    it "replaces application with updated charge and amount" do
      SecurityDepositTransactions::ReceiveService.call(
        security_deposit: security_deposit,
        party: party,
        amount_cents: 200_000,
        occurred_on: Date.new(2026, 1, 1)
      )

      charge1 = Charges::CreateService.call(
        tenancy: tenancy,
        charge_kind: "other",
        amount_cents: 50_000,
        charge_date: Date.new(2026, 1, 2),
        due_on: Date.new(2026, 1, 2)
      ).value!.data[:charge]

      charge2 = Charges::CreateService.call(
        tenancy: tenancy,
        charge_kind: "other",
        amount_cents: 70_000,
        charge_date: Date.new(2026, 1, 2),
        due_on: Date.new(2026, 1, 2)
      ).value!.data[:charge]

      app_res = SecurityDepositTransactions::ApplyService.call(
        security_deposit: security_deposit,
        charge: charge1,
        amount_cents: 50_000,
        occurred_on: Date.new(2026, 1, 5)
      )
      app_txn = app_res.value!.data[:transaction]

      correct_res = described_class.call(
        transaction: app_txn,
        charge: charge2,
        amount_cents: 60_000,
        occurred_on: Date.new(2026, 1, 5)
      )

      expect(correct_res).to be_success
      expect(charge1.deposit_applied_cents).to eq(0)
      expect(charge2.deposit_applied_cents).to eq(60_000)
      expect(security_deposit.held_cents).to eq(140_000)
    end

    it "rejects invalid charge_id rather than falling back to old charge" do
      SecurityDepositTransactions::ReceiveService.call(
        security_deposit: security_deposit,
        party: party,
        amount_cents: 200_000,
        occurred_on: Date.new(2026, 1, 1)
      )

      charge = Charges::CreateService.call(
        tenancy: tenancy,
        charge_kind: "other",
        amount_cents: 50_000,
        charge_date: Date.new(2026, 1, 2),
        due_on: Date.new(2026, 1, 2)
      ).value!.data[:charge]

      app_res = SecurityDepositTransactions::ApplyService.call(
        security_deposit: security_deposit,
        charge: charge,
        amount_cents: 50_000,
        occurred_on: Date.new(2026, 1, 5)
      )
      app_txn = app_res.value!.data[:transaction]

      correct_res = described_class.call(
        transaction: app_txn,
        charge_id: 999_999
      )

      expect(correct_res).to be_failure
      expect(correct_res.failure.code).to eq(:invalid_charge)
    end

    it "rejects correcting application date to precede target charge date" do
      SecurityDepositTransactions::ReceiveService.call(
        security_deposit: security_deposit,
        party: party,
        amount_cents: 200_000,
        occurred_on: Date.new(2026, 1, 1)
      )

      future_charge = Charges::CreateService.call(
        tenancy: tenancy,
        charge_kind: "other",
        amount_cents: 50_000,
        charge_date: Date.new(2026, 1, 10),
        due_on: Date.new(2026, 1, 10)
      ).value!.data[:charge]

      app_txn = SecurityDepositTransactions::ApplyService.call(
        security_deposit: security_deposit,
        charge: future_charge,
        amount_cents: 50_000,
        occurred_on: Date.new(2026, 1, 12)
      ).value!.data[:transaction]

      early_res = described_class.call(
        transaction: app_txn,
        occurred_on: Date.new(2026, 1, 8)
      )
      expect(early_res).to be_failure
      expect(early_res.failure.code).to eq(:precedes_charge_date)

      valid_res = described_class.call(
        transaction: app_txn,
        occurred_on: Date.new(2026, 1, 10)
      )
      expect(valid_res).to be_success
    end

    it "rejects application exceeding charge capacity or tenancy AR" do
      SecurityDepositTransactions::ReceiveService.call(
        security_deposit: security_deposit,
        party: party,
        amount_cents: 200_000,
        occurred_on: Date.new(2026, 1, 1)
      )

      charge = Charges::CreateService.call(
        tenancy: tenancy,
        charge_kind: "other",
        amount_cents: 50_000,
        charge_date: Date.new(2026, 1, 2),
        due_on: Date.new(2026, 1, 2)
      ).value!.data[:charge]

      app_res = SecurityDepositTransactions::ApplyService.call(
        security_deposit: security_deposit,
        charge: charge,
        amount_cents: 30_000,
        occurred_on: Date.new(2026, 1, 5)
      )
      app_txn = app_res.value!.data[:transaction]

      # Exceeds charge amount ($500)
      res_cap = described_class.call(transaction: app_txn, amount_cents: 60_000)
      expect(res_cap).to be_failure
      expect(res_cap.failure.code).to eq(:exceeds_charge_capacity)

      # Target charge inactive or tenancy mismatch
      other_unit = create(:rentable_unit, property: property)
      other_tenancy = create(:tenancy, rentable_unit: other_unit)
      other_charge = create(:charge, :posted, tenancy: other_tenancy, amount_cents: 50_000)

      res_mis = described_class.call(transaction: app_txn, charge: other_charge)
      expect(res_mis).to be_failure
      expect(res_mis.failure.code).to eq(:tenancy_mismatch)

      voided_charge = Charges::CreateService.call(
        tenancy: tenancy,
        charge_kind: "other",
        amount_cents: 50_000,
        charge_date: Date.new(2026, 1, 2),
        due_on: Date.new(2026, 1, 2)
      ).value!.data[:charge]
      Charges::VoidService.call(charge: voided_charge)
      res_inact = described_class.call(transaction: app_txn, charge: voided_charge.reload)
      expect(res_inact).to be_failure
      expect(res_inact.failure.code).to eq(:invalid_charge_state)
    end

    it "rejects correction resulting in negative deposit timeline" do
      rec_res = SecurityDepositTransactions::ReceiveService.call(
        security_deposit: security_deposit,
        party: party,
        amount_cents: 100_000,
        occurred_on: Date.new(2026, 1, 1)
      )
      rec_txn = rec_res.value!.data[:transaction]

      SecurityDepositTransactions::RefundService.call(
        security_deposit: security_deposit,
        party: party,
        amount_cents: 80_000,
        occurred_on: Date.new(2026, 1, 5)
      )

      # Reducing receipt from $1,000 to $500 makes Jan 5 refund exceed held balance
      res_timeline = described_class.call(transaction: rec_txn, amount_cents: 50_000)
      expect(res_timeline).to be_failure
      expect(res_timeline.failure.code).to eq(:negative_deposit_liability)
    end
  end

  describe "concurrency serialization" do
    it "safely serializes concurrent refunds" do
      SecurityDepositTransactions::ReceiveService.call(
        security_deposit: security_deposit,
        party: party,
        amount_cents: 200_000,
        occurred_on: Date.new(2026, 1, 1)
      )

      res1 = nil
      res2 = nil

      t1 = Thread.new do
        ActiveRecord::Base.connection_pool.with_connection do
          res1 = SecurityDepositTransactions::RefundService.call(
            security_deposit: SecurityDeposit.find(security_deposit.id),
            party: Party.find(party.id),
            amount_cents: 150_000,
            occurred_on: Date.current
          )
        end
      end

      t2 = Thread.new do
        ActiveRecord::Base.connection_pool.with_connection do
          res2 = SecurityDepositTransactions::RefundService.call(
            security_deposit: SecurityDeposit.find(security_deposit.id),
            party: Party.find(party.id),
            amount_cents: 150_000,
            occurred_on: Date.current
          )
        end
      end

      [ t1, t2 ].each(&:join)

      successes = [ res1, res2 ].count(&:success?)
      failures = [ res1, res2 ].count(&:failure?)

      expect(successes).to eq(1)
      expect(failures).to eq(1)
      expect(security_deposit.held_cents).to eq(50_000)
    end

    it "safely serializes concurrent refund vs application" do
      SecurityDepositTransactions::ReceiveService.call(
        security_deposit: security_deposit,
        party: party,
        amount_cents: 50_000,
        occurred_on: Date.new(2026, 1, 1)
      )

      charge = Charges::CreateService.call(
        tenancy: tenancy,
        charge_kind: "other",
        amount_cents: 50_000,
        charge_date: Date.new(2026, 1, 1),
        due_on: Date.new(2026, 1, 1),
        description: "Repair"
      ).value!.data[:charge]

      refund_res = nil
      apply_res = nil

      t1 = Thread.new do
        ActiveRecord::Base.connection_pool.with_connection do
          refund_res = SecurityDepositTransactions::RefundService.call(
            security_deposit: SecurityDeposit.find(security_deposit.id),
            party: Party.find(party.id),
            amount_cents: 50_000,
            occurred_on: Date.current
          )
        end
      end

      t2 = Thread.new do
        ActiveRecord::Base.connection_pool.with_connection do
          apply_res = SecurityDepositTransactions::ApplyService.call(
            security_deposit: SecurityDeposit.find(security_deposit.id),
            charge: Charge.find(charge.id),
            amount_cents: 50_000,
            occurred_on: Date.current
          )
        end
      end

      [ t1, t2 ].each(&:join)

      successes = [ refund_res, apply_res ].count(&:success?)
      failures = [ refund_res, apply_res ].count(&:failure?)

      expect(successes).to eq(1)
      expect(failures).to eq(1)
      expect(security_deposit.held_cents).to eq(0)
    end

    it "safely serializes concurrent application correction to Charge B vs Charge B void" do
      SecurityDepositTransactions::ReceiveService.call(
        security_deposit: security_deposit,
        party: party,
        amount_cents: 200_000,
        occurred_on: Date.new(2026, 1, 1)
      )

      charge_a = Charges::CreateService.call(
        tenancy: tenancy,
        charge_kind: "other",
        amount_cents: 50_000,
        charge_date: Date.new(2026, 1, 2),
        due_on: Date.new(2026, 1, 2)
      ).value!.data[:charge]

      charge_b = Charges::CreateService.call(
        tenancy: tenancy,
        charge_kind: "other",
        amount_cents: 50_000,
        charge_date: Date.new(2026, 1, 2),
        due_on: Date.new(2026, 1, 2)
      ).value!.data[:charge]

      app_txn = SecurityDepositTransactions::ApplyService.call(
        security_deposit: security_deposit,
        charge: charge_a,
        amount_cents: 50_000,
        occurred_on: Date.new(2026, 1, 5)
      ).value!.data[:transaction]

      correct_res = nil
      void_res = nil

      t1 = Thread.new do
        ActiveRecord::Base.connection_pool.with_connection do
          correct_res = SecurityDepositTransactions::CorrectService.call(
            transaction: SecurityDepositTransaction.find(app_txn.id),
            charge: Charge.find(charge_b.id),
            amount_cents: 50_000,
            occurred_on: Date.new(2026, 1, 5)
          )
        end
      end

      t2 = Thread.new do
        ActiveRecord::Base.connection_pool.with_connection do
          void_res = Charges::VoidService.call(
            charge: Charge.find(charge_b.id),
            reason: "Voiding Charge B"
          )
        end
      end

      [ t1, t2 ].each(&:join)

      if correct_res.success?
        # Correction won: Charge B has active application, so voiding Charge B failed
        expect(void_res).to be_failure
        expect(void_res.failure.code).to eq(:active_deposit_applications)
        expect(charge_b.reload).not_to be_voided
        expect(charge_b.security_deposit_applications.active.count).to eq(1)
      else
        # Void won: Charge B was voided, so correction failed with invalid charge state
        expect(void_res).to be_success
        expect(charge_b.reload).to be_voided
        expect(correct_res).to be_failure
        expect(correct_res.failure.code).to eq(:invalid_charge_state)
        expect(charge_b.security_deposit_applications.active.count).to eq(0)
      end
    end
  end

  describe "parameter validation and guards" do
    let(:receive_txn) do
      SecurityDepositTransactions::ReceiveService.call(
        security_deposit: security_deposit,
        party: party,
        amount_cents: 100_000,
        occurred_on: Date.new(2026, 1, 1)
      ).value!.data[:transaction]
    end

    it "rejects invalid source transaction" do
      res = described_class.call(transaction: nil)
      expect(res).to be_failure
      expect(res.failure.code).to eq(:invalid_source)
    end

    it "rejects non-positive cents" do
      res = described_class.call(transaction: receive_txn, amount_cents: 0)
      expect(res).to be_failure
      expect(res.failure.code).to eq(:invalid_input)
    end

    it "rejects invalid string amount" do
      res = described_class.call(transaction: receive_txn, amount: "invalid")
      expect(res).to be_failure
      expect(res.failure.code).to eq(:invalid_input)
    end

    it "rejects future date" do
      res = described_class.call(transaction: receive_txn, occurred_on: Date.tomorrow)
      expect(res).to be_failure
      expect(res.failure.code).to eq(:invalid_date)
    end

    it "rejects unparseable date string" do
      res = described_class.call(transaction: receive_txn, occurred_on: "invalid-date")
      expect(res).to be_failure
      expect(res.failure.code).to eq(:invalid_date)
    end

    it "rejects non-existent party_id" do
      res = described_class.call(transaction: receive_txn, party_id: 999_999)
      expect(res).to be_failure
      expect(res.failure.code).to eq(:invalid_party)
    end

    it "accepts valid party_id integer" do
      res = described_class.call(transaction: receive_txn, party_id: party2.id)
      expect(res).to be_success
      expect(res.value!.data[:replacement].party).to eq(party2)
    end

    it "rejects non-existent charge_id when correcting application" do
      SecurityDepositTransactions::ReceiveService.call(
        security_deposit: security_deposit,
        party: party,
        amount_cents: 100_000,
        occurred_on: Date.new(2026, 1, 1)
      )

      charge = Charges::CreateFeeService.call(
        tenancy: tenancy,
        charge_kind: "late_fee",
        amount_cents: 50_000,
        charge_date: Date.new(2026, 1, 1),
        due_on: Date.new(2026, 1, 1)
      ).value!.data[:charge]

      app_txn = SecurityDepositTransactions::ApplyService.call(
        security_deposit: security_deposit,
        charge: charge,
        amount_cents: 50_000,
        occurred_on: Date.new(2026, 1, 5)
      ).value!.data[:transaction]

      res = described_class.call(transaction: app_txn, charge_id: 999_999)
      expect(res).to be_failure
      expect(res.failure.code).to eq(:invalid_charge)
    end

    it "rejects party belonging to another user" do
      other_user = create(:user)
      other_party = create(:party, user: other_user)

      res = described_class.call(transaction: receive_txn, party: other_party)
      expect(res).to be_failure
      expect(res.failure.code).to eq(:party_user_mismatch)
    end

    it "rejects when party is explicitly passed as nil or blank" do
      res = described_class.call(transaction: receive_txn, party: nil, party_id: nil)
      expect(res).to be_failure
      expect(res.failure.code).to eq(:invalid_party)
    end

    it "rejects when charge is explicitly passed as nil or blank on applied correction" do
      SecurityDepositTransactions::ReceiveService.call(
        security_deposit: security_deposit,
        party: party,
        amount_cents: 100_000,
        occurred_on: Date.new(2026, 1, 1)
      )

      charge = Charges::CreateFeeService.call(
        tenancy: tenancy,
        charge_kind: "late_fee",
        amount_cents: 50_000,
        charge_date: Date.new(2026, 1, 1),
        due_on: Date.new(2026, 1, 1)
      ).value!.data[:charge]

      app_txn = SecurityDepositTransactions::ApplyService.call(
        security_deposit: security_deposit,
        charge: charge,
        amount_cents: 50_000,
        occurred_on: Date.new(2026, 1, 5)
      ).value!.data[:transaction]

      res = described_class.call(transaction: app_txn, charge: nil, charge_id: nil)
      expect(res).to be_failure
      expect(res.failure.code).to eq(:invalid_charge)
    end

    it "rejects application correction exceeding charge effective AR balance" do
      SecurityDepositTransactions::ReceiveService.call(
        security_deposit: security_deposit,
        party: party,
        amount_cents: 200_000,
        occurred_on: Date.new(2026, 1, 1)
      )

      charge = Charges::CreateFeeService.call(
        tenancy: tenancy,
        charge_kind: "late_fee",
        amount_cents: 50_000,
        charge_date: Date.new(2026, 1, 1),
        due_on: Date.new(2026, 1, 1)
      ).value!.data[:charge]

      app_txn = SecurityDepositTransactions::ApplyService.call(
        security_deposit: security_deposit,
        charge: charge,
        amount_cents: 30_000,
        occurred_on: Date.new(2026, 1, 5)
      ).value!.data[:transaction]

      # Charge effective AR is 50,000. Reversing 30,000 restores 50,000. Trying to apply 60,000 exceeds 50,000.
      res = described_class.call(transaction: app_txn, amount_cents: 60_000)
      expect(res).to be_failure
      expect(res.failure.code).to eq(:exceeds_charge_capacity)
    end

    it "accepts numeric and string amounts and string dates" do
      res1 = described_class.call(transaction: receive_txn, amount: 120.50, occurred_on: "2026-01-02")
      expect(res1).to be_success
      rep1 = res1.value!.data[:replacement]
      expect(rep1.amount_cents).to eq(12050)
      expect(rep1.occurred_on).to eq(Date.new(2026, 1, 2))

      res2 = described_class.call(transaction: rep1, amount: "150.00")
      expect(res2).to be_success
      expect(res2.value!.data[:replacement].amount_cents).to eq(15000)
    end

    it "rejects invalid dates or negative amounts" do
      res1 = described_class.call(transaction: receive_txn, occurred_on: "not-a-date")
      expect(res1).to be_failure
      expect(res1.failure.code).to eq(:invalid_date)

      res2 = described_class.call(transaction: receive_txn, amount: "-50.00")
      expect(res2).to be_failure
      expect(res2.failure.code).to eq(:invalid_input)
    end

    it "returns not_found if original journal entry is missing" do
      allow(receive_txn).to receive_message_chain(:journal_entries, :find_by).and_return(nil)
      res = described_class.call(transaction: receive_txn, amount_cents: 120_000)
      expect(res).to be_failure
      expect(res.failure.code).to eq(:not_found)
    end

    it "returns failure when reversal fails" do
      txn = receive_txn
      allow(Accounting::ReverseEntryService).to receive(:call).and_return(
        ServiceResult.failure(error: "Reversal error", code: :reversal_failed)
      )
      res = described_class.call(transaction: txn, amount_cents: 120_000)
      expect(res).to be_failure
      expect(res.failure.code).to eq(:reversal_failed)
    end

    it "returns failure when posting replacement fails" do
      txn = receive_txn # eagerly create
      allow(Accounting::PostEntryService).to receive(:call).and_return(
        ServiceResult.failure(error: "Posting error", code: :post_failed)
      )
      res = described_class.call(transaction: txn, amount_cents: 120_000)
      expect(res).to be_failure
      expect(res.failure.code).to eq(:post_failed)
    end

    it "uses charge_kind titleized when correcting an application where charge description is nil" do
      SecurityDepositTransactions::ReceiveService.call(
        security_deposit: security_deposit,
        party: party,
        amount_cents: 100_000,
        occurred_on: Date.new(2026, 1, 1)
      )

      charge = Charges::CreateFeeService.call(
        tenancy: tenancy,
        charge_kind: "late_fee",
        amount_cents: 50_000,
        charge_date: Date.new(2026, 1, 1),
        due_on: Date.new(2026, 1, 1),
        description: nil
      ).value!.data[:charge]

      app_txn = SecurityDepositTransactions::ApplyService.call(
        security_deposit: security_deposit,
        charge: charge,
        amount_cents: 50_000,
        occurred_on: Date.new(2026, 1, 5)
      ).value!.data[:transaction]

      res = described_class.call(transaction: app_txn, amount_cents: 40_000)
      expect(res).to be_success
      replacement = res.value!.data[:replacement]
      expect(replacement.amount_cents).to eq(40_000)
    end
  end
end
