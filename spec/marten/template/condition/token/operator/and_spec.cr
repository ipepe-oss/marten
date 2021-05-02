require "./spec_helper"

describe Marten::Template::Condition::Token::Operator::And do
  describe "#eval" do
    it "applies the and operator as expected" do
      condition = Marten::Template::Condition.new(["var1"])

      token = Marten::Template::Condition::Token::Operator::And.new
      token.led(condition, Marten::Template::Condition::Token::Value.new("var2"))

      token.eval(Marten::Template::Context{"var1" => false, "var2" => false}).truthy?.should be_false
      token.eval(Marten::Template::Context{"var1" => true, "var2" => false}).truthy?.should be_false
      token.eval(Marten::Template::Context{"var1" => false, "var2" => true}).truthy?.should be_false
      token.eval(Marten::Template::Context{"var1" => true, "var2" => true}).truthy?.should be_true
    end
  end

  describe "#id" do
    it "returns the expected identified" do
      Marten::Template::Condition::Token::Operator::And.new.id.should eq "and"
    end
  end

  describe "#lbp" do
    it "returns the expected left binding power" do
      Marten::Template::Condition::Token::Operator::And.new.lbp.should eq 7_u8
    end
  end
end
