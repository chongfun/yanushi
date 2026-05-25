class CreatePaymentDocuments < ActiveRecord::Migration[8.1]
  def change
    create_table :payment_documents do |t|
      t.references :user, null: false, foreign_key: true
      t.binary :attachment_file
      t.string :attachment_filename
      t.string :attachment_content_type

      t.timestamps
    end
  end
end
