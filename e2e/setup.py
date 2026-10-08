import json, subprocess, time, urllib.request
RPC='http://127.0.0.1:8545'
def rpc(m, p=[]):
    r=urllib.request.Request(RPC, data=json.dumps({"jsonrpc":"2.0","id":1,"method":m,"params":p}).encode(), headers={'Content-Type':'application/json'})
    out=json.loads(urllib.request.urlopen(r).read()); 
    if 'error' in out: raise Exception(out['error'])
    return out['result']
def art(f,c): return json.load(open(f'out/{f}/{c}.json'))
acct=rpc('eth_accounts')[0]
def deploy(bytecode):
    h=rpc('eth_sendTransaction',[{"from":acct,"data":bytecode,"gas":hex(8_000_000)}])
    for _ in range(100):
        rc=rpc('eth_getTransactionReceipt',[h])
        if rc: return rc['contractAddress']
        time.sleep(0.1)
imd=deploy(art('Mocks.sol','MockIMD')['bytecode']['object'])
# The house key: HOUSE_MODULUS (from house/keygen.mjs), or the fixed test key that the tests use.
house=__import__('os').environ.get('HOUSE_MODULUS') or subprocess.check_output(['node','test/fixtures/house-test-key.mjs','modulus']).decode().strip()
modulus=bytes.fromhex(house.removeprefix('0x'))
if len(modulus) != 256: raise ValueError('HOUSE_MODULUS must be exactly 256 bytes')
words=['0x'+modulus[i:i+32].hex() for i in range(0, 256, 32)]
enc=subprocess.check_output(['cast','abi-encode','c(address,address,uint256,uint256,bytes32,bytes32,bytes32,bytes32,bytes32,bytes32,bytes32,bytes32)',
    acct, imd, str(15*10**16), str(5*10**17), *words]).decode().strip()
derby=deploy(art('SwarmDerby.sol','SwarmDerby')['bytecode']['object']+enc[2:])
# mint 10 IMD to player
data=subprocess.check_output(['cast','calldata','mint(address,uint256)',acct,str(10*10**18)]).decode().strip()
rpc('eth_sendTransaction',[{"from":acct,"to":imd,"data":data}])
# an agent wallet (anvil account #1) with IMD for the agent league
agent=rpc('eth_accounts')[1]
data=subprocess.check_output(['cast','calldata','mint(address,uint256)',agent,str(10*10**18)]).decode().strip()
rpc('eth_sendTransaction',[{"from":acct,"to":imd,"data":data}])
json.dump({"acct":acct,"imd":imd,"derby":derby}, open('e2e/addrs.json','w'))
print(acct, imd, derby)
