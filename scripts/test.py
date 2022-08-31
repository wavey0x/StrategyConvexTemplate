import math
import brownie
from datetime import datetime, timezone
from brownie import Contract, chain, accounts,web3

def main():
    ms = accounts.at('0x5C8898f8E0F9468D4A677887bC03EE2659321012', force=True)
    ychad = accounts.at(web3.ens.resolve('ychad.eth'), force=True)
    t = Contract('0xdaDfD00A2bBEb1abc4936b1644a3033e1B653228',owner=ms)
    v = Contract('0xe92AE2cF5b373c1713eB5855D4D3aF81D8a8aCAE',owner=ychad)
    v.acceptGovernance()
    holder = accounts.at('0xE97CB3a6A0fb5DA228976F3F2B8c37B6984e7915', force=True)
    strat = Contract(v.withdrawalQueue(0), owner=ychad)
    t.approve(v,2**256-1)
    v.deposit({'from':ms})
    