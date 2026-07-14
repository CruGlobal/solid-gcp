class CreateJobRuns < ActiveRecord::Migration[8.1]
  def change
    create_table :job_runs do |t|
      t.string :job_class, null: false
      t.text :args
      t.text :note
      t.datetime :ran_at, null: false
      t.index :ran_at
    end
  end
end
