export const metadata = { title: 'Preview proxy POC' };

export default function RootLayout({ children }) {
  return (
    <html lang="en">
      <body style={{ fontFamily: 'system-ui, sans-serif', maxWidth: 720, margin: '40px auto', padding: '0 16px' }}>
        {children}
      </body>
    </html>
  );
}
