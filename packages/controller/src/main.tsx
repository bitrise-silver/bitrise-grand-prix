import { BitkitProvider } from '@bitrise/bitkit-v2';
import { StrictMode } from 'react';
import { createRoot } from 'react-dom/client';
import { createBrowserRouter, RouterProvider } from 'react-router';
import JoinPage from './pages/JoinPage';
import QrScreenPage from './pages/QrScreenPage';
import SessionPage from './pages/SessionPage';
import SessionsPage from './pages/SessionsPage';

const router = createBrowserRouter([
  { path: '/', element: <SessionsPage /> },
  { path: '/session/:code', element: <SessionPage /> },
  { path: '/session/:code/qr', element: <QrScreenPage /> },
  { path: '/join/:code', element: <JoinPage /> },
  { path: '*', element: <SessionsPage /> },
]);

createRoot(document.getElementById('root')!).render(
  <StrictMode>
    <BitkitProvider>
      <RouterProvider router={router} />
    </BitkitProvider>
  </StrictMode>,
);
