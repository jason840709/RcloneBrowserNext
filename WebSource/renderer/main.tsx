import React from 'react';
import { createRoot } from 'react-dom/client';
import App from './App';
import { installNativeBridge } from './bridge';
import './styles.css';

installNativeBridge();

document.addEventListener('keydown', () => { document.documentElement.dataset.input = 'keyboard'; }, { capture: true });
document.addEventListener('pointerdown', () => { document.documentElement.dataset.input = 'pointer'; }, { capture: true });

class ErrorBoundary extends React.Component<React.PropsWithChildren, {error: string}> {
  state = { error: '' };
  static getDerivedStateFromError(error: Error) { return { error: error.message }; }
  render() {
    if (this.state.error) {
      const language = document.documentElement.lang;
      return <main className="startup"><h1>{language === 'ja' ? '画面にエラーが発生しました' : language === 'en' ? 'Interface error' : '介面發生錯誤'}</h1><p>{this.state.error}</p><button type="button" onClick={() => window.location.reload()}>{language === 'ja' ? '再読み込み' : language === 'en' ? 'Reload' : '重新載入'}</button></main>;
    }
    return this.props.children;
  }
}

createRoot(document.getElementById('root')!).render(<ErrorBoundary><App/></ErrorBoundary>);
