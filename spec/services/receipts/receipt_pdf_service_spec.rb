require "rails_helper"

RSpec.describe Receipts::ReceiptPdfService, type: :service do
  let(:user) { create(:user) }
  let(:property) { create(:property, user: user, address: "123 Main St") }
  let(:unit) { create(:rentable_unit, property: property, name: "Unit 4B") }
  let(:tenancy) { create(:tenancy, rentable_unit: unit) }
  let(:payer_party) { create(:party, user: user, display_name: "Alice Walker") }
  let(:receipt) do
    create(:receipt,
      user: user,
      tenancy: tenancy,
      payer_party: payer_party,
      amount_cents: 125_000,
      received_on: Date.new(2026, 1, 15),
      payment_method: "zelle",
      external_reference: "ZEL123",
      memo: "January Rent"
    )
  end

  let(:view_context) { double(number_to_currency: "$1,250.00") }
  let(:pdf) { instance_double(Prawn::Document, text: nil, move_down: nil, render: "pdf-data") }

  describe ".call" do
    it "renders receipt details into a PDF" do
      allow(Prawn::Document).to receive(:new).and_return(pdf)

      result = described_class.call(receipt: receipt, view_context: view_context)

      expect(result).to eq("pdf-data")
      expect(pdf).to have_received(:text).with("Payment Receipt", size: 30, style: :bold)
      expect(pdf).to have_received(:text).with("Receipt ID: ##{receipt.id}")
      expect(pdf).to have_received(:text).with("Payment Date: January 15, 2026")
      expect(pdf).to have_received(:text).with("Amount: $1,250.00")
      expect(pdf).to have_received(:text).with("Payer: Alice Walker")
      expect(pdf).to have_received(:text).with("Method: Zelle")
      expect(pdf).to have_received(:text).with("Transaction / Reference: ZEL123")
      expect(pdf).to have_received(:text).with("Property: 123 Main St")
      expect(pdf).to have_received(:text).with("Unit: #{unit.display_name}")
      expect(pdf).to have_received(:text).with("Tenancy: ##{tenancy.id}")
    end

    it "includes a clear voided notice for a voided receipt" do
      receipt.update_columns(voided_at: Time.current)
      allow(Prawn::Document).to receive(:new).and_return(pdf)

      result = described_class.call(receipt: receipt, view_context: view_context)
      expect(result).to eq("pdf-data")
      expect(pdf).to have_received(:text).with("[VOIDED - INACTIVE RECORD]", size: 12, style: :bold, color: "CC0000")
    end

    it "includes a clear corrected notice for a superseded receipt" do
      replacement = create(:receipt, tenancy: tenancy, payer_party: payer_party)
      receipt.update_columns(voided_at: Time.current, superseded_by_id: replacement.id)
      allow(Prawn::Document).to receive(:new).and_return(pdf)

      result = described_class.call(receipt: receipt, view_context: view_context)
      expect(result).to eq("pdf-data")
      expect(pdf).to have_received(:text).with("[CORRECTED - REPLACED BY RECEIPT ##{replacement.id}]", size: 12, style: :bold, color: "CC0000")
    end

    it "includes a replacement notice for a receipt that replaces a superseded one" do
      original = create(:receipt, tenancy: tenancy, payer_party: payer_party)
      original.update_columns(voided_at: Time.current, superseded_by_id: receipt.id)
      allow(Prawn::Document).to receive(:new).and_return(pdf)

      result = described_class.call(receipt: receipt, view_context: view_context)
      expect(result).to eq("pdf-data")
      expect(pdf).to have_received(:text).with("[REPLACEMENT FOR RECEIPT ##{original.id}]", size: 12, style: :bold, color: "008800")
    end

    it "handles receipt without external_reference or memo" do
      receipt.update_columns(external_reference: nil, memo: nil)
      allow(Prawn::Document).to receive(:new).and_return(pdf)

      result = described_class.call(receipt: receipt, view_context: view_context)
      expect(result).to eq("pdf-data")
    end

    it "handles receipt without payer_party or rentable_unit" do
      allow(receipt).to receive(:payer_party).and_return(nil)
      allow(tenancy).to receive(:rentable_unit).and_return(nil)
      allow(Prawn::Document).to receive(:new).and_return(pdf)

      result = described_class.call(receipt: receipt, view_context: view_context)
      expect(result).to eq("pdf-data")
    end

    it "handles receipt without tenancy" do
      allow(receipt).to receive(:tenancy).and_return(nil)
      allow(Prawn::Document).to receive(:new).and_return(pdf)

      result = described_class.call(receipt: receipt, view_context: view_context)
      expect(result).to eq("pdf-data")
    end

    it "handles receipt with only external_reference or only memo" do
      receipt.update_columns(external_reference: "ZEL123", memo: nil)
      allow(Prawn::Document).to receive(:new).and_return(pdf)
      expect(described_class.call(receipt: receipt, view_context: view_context)).to eq("pdf-data")

      receipt.update_columns(external_reference: nil, memo: "Some memo")
      expect(described_class.call(receipt: receipt, view_context: view_context)).to eq("pdf-data")
    end

    it "generates genuine PDF binary bytes" do
      real_view_context = ActionController::Base.new.view_context
      real_pdf = described_class.call(receipt: receipt, view_context: real_view_context)
      expect(real_pdf).to be_present
      expect(real_pdf).to start_with("%PDF-")
    end
  end
end
