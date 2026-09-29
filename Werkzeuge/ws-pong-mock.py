import socket, threading, struct, hashlib, base64, sys, time, os
PORT=int(sys.argv[1]); PONG=float(sys.argv[2])  # Sekunden; 0 = nie
T0=time.time()
def log(*a): print("[%6.1fs]"%(time.time()-T0),*a,flush=True)
def frame(op,payload=b""):
    n=len(payload)
    h=bytes([0x80|op])
    if n<126: h+=bytes([n])
    elif n<65536: h+=bytes([126])+struct.pack(">H",n)
    else: h+=bytes([127])+struct.pack(">Q",n)
    return h+payload
def recvn(c,n):
    b=b""
    while len(b)<n:
        d=c.recv(n-len(b))
        if not d: raise EOFError
        b+=d
    return b
def handle(c,addr):
    try:
        req=b""
        while b"\r\n\r\n" not in req: req+=c.recv(4096)
        hd=dict(l.split(": ",1) for l in req.decode().split("\r\n")[1:] if ": " in l)
        acc=base64.b64encode(hashlib.sha1((hd["Sec-WebSocket-Key"]+"258EAFA5-E914-47DA-95CA-C5AB0DC85B11").encode()).digest()).decode()
        c.sendall(("HTTP/1.1 101 Switching Protocols\r\nUpgrade: websocket\r\nConnection: Upgrade\r\nSec-WebSocket-Accept: %s\r\n\r\n"%acc).encode())
        log("verbunden",addr, req.split(b"\r\n")[0].decode())
        lock=threading.Lock()
        alive=[True]
        def send(op,p=b""):
            with lock: c.sendall(frame(op,p))
        send(1,b'{"MessageType":"ForceKeepAlive","Data":60}')
        def pongs():
            while alive[0] and PONG>0:
                time.sleep(PONG)
                if not alive[0]: return
                try: send(10,b""); log("unaufgeforderter Pong gesendet")
                except Exception: return
        threading.Thread(target=pongs,daemon=True).start()
        while True:
            h=recvn(c,2); op=h[0]&15; ln=h[1]&127; mask=h[1]&128
            if ln==126: ln=struct.unpack(">H",recvn(c,2))[0]
            elif ln==127: ln=struct.unpack(">Q",recvn(c,8))[0]
            m=recvn(c,4) if mask else b""
            p=recvn(c,ln)
            if mask: p=bytes(x^m[i%4] for i,x in enumerate(p))
            log("Frame op=%d %r"%(op,p[:60]))
            if op==9: send(10,p)
            if op==8: send(8,p[:2]); break
    except Exception as e:
        log("Ende:",repr(e))
    finally:
        alive[0]=False; c.close(); log("Verbindung zu")
s=socket.socket(); s.setsockopt(socket.SOL_SOCKET,socket.SO_REUSEADDR,1); s.bind(("127.0.0.1",PORT)); s.listen(5)
log("lausche",PORT,"Pong alle",PONG)
while True:
    c,a=s.accept(); threading.Thread(target=handle,args=(c,a),daemon=True).start()
