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

ActiveRecord::Schema[8.1].define(version: 2026_07_14_055959) do
  create_table "job_runs", force: :cascade do |t|
    t.text "args"
    t.string "job_class", null: false
    t.text "note"
    t.datetime "ran_at", null: false
    t.index ["ran_at"], name: "index_job_runs_on_ran_at"
  end

  create_table "solid_gcp_blocked_jobs", force: :cascade do |t|
    t.string "concurrency_key", null: false
    t.datetime "created_at", null: false
    t.datetime "expires_at", null: false
    t.text "serialized_envelope", null: false
    t.datetime "updated_at", null: false
    t.index ["concurrency_key"], name: "index_solid_gcp_blocked_jobs_on_concurrency_key"
    t.index ["expires_at"], name: "index_solid_gcp_blocked_jobs_on_expires_at"
  end

  create_table "solid_gcp_failed_jobs", force: :cascade do |t|
    t.string "active_job_id"
    t.text "backtrace"
    t.datetime "created_at", null: false
    t.string "error_class"
    t.text "error_message"
    t.datetime "failed_at", null: false
    t.string "job_class"
    t.string "queue_name"
    t.text "serialized_envelope", null: false
    t.datetime "updated_at", null: false
    t.index ["active_job_id"], name: "index_solid_gcp_failed_jobs_on_active_job_id"
    t.index ["job_class"], name: "index_solid_gcp_failed_jobs_on_job_class"
  end

  create_table "solid_gcp_semaphores", force: :cascade do |t|
    t.datetime "created_at", null: false
    t.datetime "expires_at", null: false
    t.string "key", null: false
    t.datetime "updated_at", null: false
    t.integer "value", default: 1, null: false
    t.index ["expires_at"], name: "index_solid_gcp_semaphores_on_expires_at"
    t.index ["key"], name: "index_solid_gcp_semaphores_on_key", unique: true
  end
end
