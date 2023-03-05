require "./spec_helper"

describe Marten::DB::Migration::Operation::RunCode do
  describe "#describe" do
    it "returns the expected description" do
      operation = Marten::DB::Migration::Operation::RunCode.new(->{ nil })
      operation.describe.should eq "Run custom Crystal code"
    end
  end

  describe "#mutate_db_backward" do
    it "run the backward proc" do
      from_project_state = Marten::DB::Management::ProjectState.new([] of Marten::DB::Management::TableState)
      to_project_state = Marten::DB::Management::ProjectState.new([] of Marten::DB::Management::TableState)
      schema_editor = Marten::DB::Management::SchemaEditor.for(Marten::DB::Connection.default)

      var = nil
      operation = Marten::DB::Migration::Operation::RunCode.new(
        ->{ var = "forward" },
        ->{ var = "backward" }
      )

      operation.mutate_db_backward("my_app", schema_editor, from_project_state, to_project_state)

      var.should eq "backward"
    end

    it "does nothing if the operation does not have a backward proc" do
      from_project_state = Marten::DB::Management::ProjectState.new([] of Marten::DB::Management::TableState)
      to_project_state = Marten::DB::Management::ProjectState.new([] of Marten::DB::Management::TableState)
      schema_editor = Marten::DB::Management::SchemaEditor.for(Marten::DB::Connection.default)

      var = nil
      operation = Marten::DB::Migration::Operation::RunCode.new(->{ var = "forward" })

      operation.mutate_db_backward("my_app", schema_editor, from_project_state, to_project_state)

      var.should be_nil
    end
  end

  describe "#mutate_db_forward" do
    it "run the forward proc" do
      from_project_state = Marten::DB::Management::ProjectState.new([] of Marten::DB::Management::TableState)
      to_project_state = Marten::DB::Management::ProjectState.new([] of Marten::DB::Management::TableState)
      schema_editor = Marten::DB::Management::SchemaEditor.for(Marten::DB::Connection.default)

      var = nil
      operation = Marten::DB::Migration::Operation::RunCode.new(
        ->{ var = "forward" },
        ->{ var = "backward" }
      )

      operation.mutate_db_forward("my_app", schema_editor, from_project_state, to_project_state)

      var.should eq "forward"
    end
  end

  describe "#mutate_state_forward" do
    it "does nothing" do
      project_state = Marten::DB::Management::ProjectState.new([] of Marten::DB::Management::TableState)

      var = nil
      operation = Marten::DB::Migration::Operation::RunCode.new(
        ->{ var = "forward" },
        ->{ var = "backward" }
      )

      operation.mutate_state_forward("my_app", project_state).should be_nil
      var.should be_nil
    end
  end

  describe "#serialize" do
    it "raises NotImplementedError" do
      operation = Marten::DB::Migration::Operation::RunCode.new(->{ nil })
      expect_raises(NotImplementedError) { operation.serialize }
    end
  end
end
