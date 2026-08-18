"""Behavioral mirror of ConfirmGate / ChipMoneyCommitPlan (no Flutter)."""


def aborted(result):
    return result is None


def funding_required(typ, amount):
    if amount <= 0:
        return False
    return typ in ("buyIn", "rebuy", "cashOut")


def plan(typ, amount, buy_in=None, cash_out=None, dismissed=False, chips=None):
    if funding_required(typ, amount) and (
        dismissed
        or (typ == "cashOut" and cash_out is None)
        or (typ in ("buyIn", "rebuy") and buy_in is None)
    ):
        return {"commit": False, "fin_out": False, "fin_in": False, "chips": False}
    if typ == "cashOut" and amount <= 0:
        return {"commit": True, "fin_out": False, "fin_in": False, "chips": False}
    writes_out = typ == "cashOut" and cash_out not in (None, "notRecorded")
    writes_in = typ in ("buyIn", "rebuy") and buy_in not in (None, "notRecorded")
    writes_chips = bool(chips)
    return {
        "commit": True,
        "fin_out": writes_out,
        "fin_in": writes_in,
        "chips": writes_chips,
    }


def main():
    assert aborted(None) and not aborted("paidCash")
    assert funding_required("cashOut", 700)
    assert not funding_required("cashOut", 0)
    p = plan("cashOut", 700, cash_out="paidCash")
    assert p["commit"] and p["fin_out"]
    p = plan("cashOut", 700, cash_out=None)
    assert not p["commit"] and not p["fin_out"]
    p = plan("cashOut", 700, cash_out="paidCash", dismissed=True)
    assert not p["commit"]
    p = plan("cashOut", 700, cash_out="notRecorded")
    assert p["commit"] and not p["fin_out"]
    p = plan("cashOut", 0)
    assert p["commit"] and not p["fin_out"]
    p = plan("buyIn", 1000, buy_in=None)
    assert not p["commit"]
    p = plan("buyIn", 1000, buy_in="paidCash")
    assert p["commit"] and p["fin_in"]
    p = plan("rebuy", 200, buy_in="credit", chips={})
    assert p["commit"] and not p["chips"]
    print("confirm_gate_mirror: 11/11 PASS")


if __name__ == "__main__":
    main()
