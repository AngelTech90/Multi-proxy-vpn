import time
import random
# Si vas por API, te recomiendo instalar: pip install tls_client
# Si vas por Navegador: pip install playwright playwright-stealth

def get_active_proxy_ports():
    # Estos son los puertos SOCKS5 de tu multi-vpn-proxy.sh
    # Idealmente, acá meteríamos una validación (como el 'test' de tu script)
    # para asegurar que el puerto responde antes de usarlo.
    return [1080, 1081, 1082, 1083, 1084, 1085, 1086, 1087, 1088, 1089, 1090, 1091]

def chunk_accounts(accounts, num_chunks):
    """Divide las cuentas en lotes equitativos para cada proxy"""
    k, m = divmod(len(accounts), num_chunks)
    return [accounts[i*k+min(i, m):(i+1)*k+min(i+1, m)] for i in range(num_chunks)]

def process_account(account_email, proxy_port):
    """
    Acá va la magia real.
    """
    proxy_url = f"socks5://127.0.0.1:{proxy_port}"
    
    print(f"[+] Procesando {account_email} a través de VPN en puerto {proxy_port}")
    
    # === EJEMPLO SI USAS REQUESTS/TLS-CLIENT (Recomendado para evitar JA3 fingerprinting) ===
    # session = tls_client.Session(
    #     client_identifier="chrome_120", # Engaña a Google simulando un Chrome real
    #     random_tls_extension_order=True
    # )
    # session.proxies = {"http": proxy_url, "https": proxy_url}
    # response = session.get("https://accounts.google.com/...")
    
    # === SIMULACIÓN ===
    # Simulamos el delay humano (clave para no ser detectado)
    time.sleep(random.uniform(2.0, 5.0))
    print(f"    -> OK: {account_email} completado.")

def main():
    # 1. Obtenemos nuestros puertos VPN disponibles
    ports = get_active_proxy_ports()
    
    # 2. Simulamos 100 cuentas de Google
    accounts = [f"test_account_{i}@gmail.com" for i in range(1, 101)]
    print(f"[*] Total de cuentas a procesar: {len(accounts)}")
    print(f"[*] Total de proxies VPN disponibles: {len(ports)}")
    
    # 3. Dividimos las cuentas en lotes por cada proxy (aprox 8-9 cuentas por IP)
    batches = chunk_accounts(accounts, len(ports))
    
    for i, port in enumerate(ports):
        current_batch = batches[i]
        print(f"\n[=== Cambiando a IP de Proxy {port} ({len(current_batch)} cuentas) ===]")
        
        for account in current_batch:
            try:
                process_account(account, port)
            except Exception as e:
                print(f"    -> ERROR con {account}: {e}")
            
            # Delay entre cuentas de la misma IP para no levantar sospechas
            time.sleep(random.uniform(1.0, 3.0))

if __name__ == "__main__":
    main()
