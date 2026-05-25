class RenamePaymentReceiptIngestionsToPaymentIngestions < ActiveRecord::Migration[8.1]
  def change
    rename_table :payment_receipt_ingestions, :payment_ingestions
  end
end
