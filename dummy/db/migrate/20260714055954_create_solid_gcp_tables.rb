# frozen_string_literal: true

class CreateSolidGcpTables < ActiveRecord::Migration[8.1]
  def change
    create_table :solid_gcp_semaphores do |t|
      t.string :key, null: false
      t.integer :value, null: false, default: 1
      t.datetime :expires_at, null: false
      t.timestamps

      t.index :key, unique: true
      t.index :expires_at
    end

    create_table :solid_gcp_blocked_jobs do |t|
      t.string :concurrency_key, null: false
      t.text :serialized_envelope, null: false
      t.datetime :expires_at, null: false
      t.timestamps

      t.index :concurrency_key
      t.index :expires_at
    end

    create_table :solid_gcp_failed_jobs do |t|
      t.string :active_job_id
      t.string :job_class
      t.string :queue_name
      t.text :serialized_envelope, null: false
      t.string :error_class
      t.text :error_message
      t.text :backtrace
      t.datetime :failed_at, null: false
      t.timestamps

      t.index :active_job_id
      t.index :job_class
    end
  end
end
